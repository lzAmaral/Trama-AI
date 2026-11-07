import Foundation
import Darwin
import Testing
@testable import TramaCore

struct DeliveryWorkflowTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
        func set(_ value: Date) { lock.withLock { date = value } }
    }

    private struct Context: Sendable {
        let directory: URL
        let clock: Clock
        var repository: DeliveryWorkflowRepository {
            DeliveryWorkflowRepository(engineHome: directory, now: { clock.now() })
        }
        func ref(_ id: UInt32 = 1, born: Date? = nil) -> DeliveryAgentReference {
            .init(id: id, createdAtMs: UInt64((born ?? clock.now().addingTimeInterval(-60)).timeIntervalSince1970 * 1_000))
        }
        func observe(_ state: String, ref: DeliveryAgentReference) throws -> DeliveryWorkflowSnapshot {
            try repository.observe([.init(agentRef: ref, state: state)])
        }
    }

    private func withStore(_ body: (Context) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(Context(directory: directory, clock: Clock()))
    }

    @Test func baselineDoneExitedAndUnknownNeverInventDeliveries() throws {
        try withStore { context throws in
            let ref = context.ref()
            #expect(try context.repository.load() == DeliveryWorkflowSnapshot())
            #expect(try context.observe("done", ref: ref).interventions.isEmpty)
            #expect(try context.observe("unknown", ref: ref).interventions.isEmpty)
            #expect(try context.observe("done", ref: ref).interventions.isEmpty)
            #expect(try context.observe("exited", ref: ref).interventions.isEmpty)
            #expect(try context.repository.observe([]).interventions.isEmpty)
            #expect(try context.repository.exportMetrics() == DeliveryMetricsExport())
        }
    }

    @Test func successfulTransitionsDeduplicatePollsAndRestartsAndRequireExplicitReview() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.observe("working", ref: ref)
            context.clock.advance(3)
            let first = try context.observe("done", ref: ref)
            let item = try #require(first.interventions.first)
            #expect(item.kind == .reviewAvailable)
            #expect(item.isPending)
            #expect(try context.observe("done", ref: ref).interventions == [item])
            #expect(try context.observe("unknown", ref: ref).interventions == [item])
            #expect(try context.observe("done", ref: ref).interventions == [item])
            let exited = try context.observe("exited", ref: ref)
            #expect(exited.interventions[0].isPending)
            _ = try context.observe("working", ref: ref)
            let second = try context.observe("done", ref: ref)
            #expect(second.interventions.count == 2)
            #expect(second.interventions.allSatisfy { $0.isPending })
            let reviewed = try context.repository.recordReviewedDelivery(agentRef: ref, diffVersion: "v1", diffIsEmpty: false)
            #expect(reviewed.interventions.allSatisfy { $0.reviewedAt != nil && $0.resolvedAt == nil })
            #expect(reviewed.metrics.summary.reviewedDeliveries == 0)
            #expect(try context.repository.load() == reviewed)
        }
    }

    @Test func pausedAndLostResolveOnlyOnKnownEvidenceAndNeverOnMissingPollData() throws {
        try withStore { context in
            let ref = context.ref()
            let paused = try context.observe("paused", ref: ref)
            #expect(paused.interventions.count == 1)
            #expect(try context.observe("paused", ref: ref).interventions == paused.interventions)
            _ = try context.repository.observe([])
            _ = try context.observe("unknown", ref: ref)
            #expect(try context.repository.load().interventions[0].isPending)
            let lost = try context.observe("lost", ref: ref)
            #expect(lost.interventions.map(\.kind) == [.paused, .lost])
            #expect(lost.interventions.allSatisfy { $0.isPending })
            let returned = try context.observe("paused", ref: ref)
            #expect(returned.interventions.count == 2)
            #expect(returned.interventions[0].isPending)
            #expect(returned.interventions[1].resolvedAt != nil)
            #expect(try context.observe("working", ref: ref).interventions.allSatisfy { !$0.isPending })
            let pausedAgain = try context.observe("paused", ref: ref)
            #expect(pausedAgain.interventions.count == 3)
            #expect(pausedAgain.interventions[2].id != paused.interventions[0].id)
        }
    }

    @Test func baselineLostAndRecycledIDsHaveDistinctIdentityAndHome() throws {
        try withStore { context in
            let old = context.ref()
            let first = try context.observe("lost", ref: old)
            context.clock.advance(1)
            let new = context.ref(born: context.clock.now())
            #expect(new.id == old.id)
            #expect(new != old)
            #expect(try context.observe("done", ref: new).interventions == first.interventions)
            let second = try context.observe("paused", ref: new)
            #expect(second.interventions.count == 2)
            #expect(second.interventions[0].agentRef != second.interventions[1].agentRef)
            let separate = DeliveryWorkflowRepository(engineHome: context.directory.appendingPathComponent("other"))
            #expect(try separate.load().interventions.isEmpty)
        }
    }

    @Test func readingDismissingAndDeliveringDoNotClaimObservedResolution() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.setMetricsEnabled(true)
            let item = try #require(context.observe("paused", ref: ref).interventions.first)
            context.clock.advance(4)
            let read = try context.repository.markRead(item.id)
            #expect(read.interventions[0].readAt == context.clock.now())
            #expect(read.interventions[0].inputDeliveredAt == nil)
            #expect(read.interventions[0].isPending)
            context.clock.advance(6)
            let sentAt = context.clock.now()
            context.clock.advance(20)
            let delivered = try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt)
            #expect(delivered.interventions[0].inputDeliveredAt == context.clock.now())
            #expect(delivered.interventions[0].resolvedAt == nil)
            #expect(delivered.interventions[0].isPending)
            #expect(delivered.metrics.summary.openedInterventions == 1)
            #expect(delivered.metrics.summary.deliveredInputs == 1)
            #expect(delivered.metrics.summary.totalSecondsToOpen == 4)
            #expect(delivered.metrics.summary.totalSecondsToInput == 30)
            _ = try context.repository.markRead(item.id)
            #expect(try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt).metrics == delivered.metrics)
            let dismissed = try context.repository.dismissIntervention(item.id)
            #expect(dismissed.interventions[0].dismissedAt != nil)
            #expect(dismissed.interventions[0].resolvedAt == nil)
            #expect(!dismissed.interventions[0].isPending)
        }
    }

    @Test func lateAcknowledgmentCannotAttachToANewPausedOccurrence() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.observe("paused", ref: ref)
            context.clock.advance(1)
            let sentAt = context.clock.now()
            _ = try context.observe("working", ref: ref)
            context.clock.advance(1)
            _ = try context.observe("paused", ref: ref)
            context.clock.advance(1)
            let late = try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt)
            #expect(late.interventions.count == 2)
            #expect(late.interventions[0].inputDeliveredAt == context.clock.now())
            #expect(late.interventions[1].inputDeliveredAt == nil)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) {
                try context.repository.markInputDelivered(agentRef: ref, sentAt: context.clock.now().addingTimeInterval(100))
            }
        }
    }

    @Test func acknowledgmentAfterObservedResolutionRecordsTheOriginalDeliveryOnlyOnce() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.observe("paused", ref: ref)
            context.clock.advance(1)
            let sentAt = context.clock.now()
            context.clock.advance(1)
            _ = try context.observe("working", ref: ref)
            context.clock.advance(1)
            let result = try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt)
            #expect(result.interventions[0].resolvedAt != nil)
            #expect(result.interventions[0].inputDeliveredAt == context.clock.now())
            #expect(result.metrics.summary.deliveredInputs == 1)
            #expect(result.metrics.summary.totalSecondsToInput == 3)
            #expect(try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt) == result)
        }
    }

    @Test func inputStartedAfterAnOccurrenceEndedDoesNotCountAsItsResponse() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.observe("paused", ref: ref)
            context.clock.advance(1)
            _ = try context.observe("working", ref: ref)
            context.clock.advance(1)
            let sentAt = context.clock.now()
            context.clock.advance(1)
            let result = try context.repository.markInputDelivered(agentRef: ref, sentAt: sentAt)
            #expect(result.interventions[0].inputDeliveredAt == nil)
            #expect(result.metrics.summary.deliveredInputs == 0)
        }
    }

    @Test func commentsStayOnExactDiffAcrossRestartAndEditsClearSentStatus() throws {
        try withStore { context in
            let ref = context.ref()
            let old = try context.repository.addComment(agentRef: ref, diffVersion: "old", line: 5, text: "Rever condição")
            let new = try context.repository.addComment(agentRef: ref, diffVersion: "new", line: 5, text: "Rever erro")
            #expect(old.id != new.id)
            let sent = try context.repository.markCommentsSent([old])
            #expect(sent.comments[0].sentAt != nil)
            #expect(sent.comments[1].sentAt == nil)
            #expect(try context.repository.load().comments.map(\.diffVersion) == ["old", "new"])
            let edited = try context.repository.updateComment(old.id, text: "Verificar caso vazio")
            #expect(edited.comments[0].sentAt == nil)
            #expect(edited.comments[0].diffVersion == "old")
            #expect(edited.comments[0].line == 5)
            #expect(edited.comments[0].updatedAt > old.updatedAt)
            let resolved = try context.repository.resolveComment(old.id)
            #expect(resolved.comments[0].resolvedAt != nil)
            #expect(resolved.comments[1] == new)
        }
    }

    @Test func concurrentEditedBatchIsRejectedAtomicallyIncludingSameClockABA() throws {
        try withStore { context in
            let ref = context.ref()
            let first = try context.repository.addComment(agentRef: ref, diffVersion: "v", line: 2, text: "Um")
            let second = try context.repository.addComment(agentRef: ref, diffVersion: "v", line: 3, text: "Dois")
            _ = try context.repository.updateComment(second.id, text: "Três")
            _ = try context.repository.updateComment(second.id, text: "Dois")
            let before = try Data(contentsOf: context.repository.fileURL)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.staleComment) {
                try context.repository.markCommentsSent([first, second])
            }
            #expect(try Data(contentsOf: context.repository.fileURL) == before)
            let reloaded = try context.repository.load()
            #expect(reloaded.comments[1].updatedAt > second.updatedAt)
            #expect(reloaded.comments.allSatisfy { $0.sentAt == nil })
            #expect(try context.repository.markCommentsSent(reloaded.comments).comments.allSatisfy { $0.sentAt != nil })
        }
    }

    @Test func metricsAreOffUntilOptInAndOptOutClearsOnlyTelemetry() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.recordVisit()
            _ = try context.repository.recordReviewedDelivery(agentRef: ref, diffVersion: "v", diffIsEmpty: false)
            #expect(try context.repository.exportMetrics() == DeliveryMetricsExport())
            _ = try context.observe("paused", ref: ref)
            _ = try context.repository.addComment(agentRef: ref, diffVersion: "v", line: 1, text: "Nota")
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.repository.recordVisit()
            #expect(try context.repository.exportMetrics().visits == 1)
            let reset = try context.repository.setMetricsEnabled(false)
            #expect(reset.metrics == DeliveryMetrics())
            #expect(reset.comments.count == 1)
            #expect(reset.interventions.count == 1)
            #expect(try context.repository.load() == reset)
            let newWindow = try context.repository.setMetricsEnabled(true)
            #expect(newWindow.metrics.summary == DeliveryMetricsExport())
        }
    }

    @Test func explicitNonemptyReviewCountsOnceAndExcludesPreOptInAgents() throws {
        try withStore { context in
            let old = context.ref()
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.repository.recordReviewedDelivery(agentRef: old, diffVersion: "v", diffIsEmpty: false)
            #expect(try context.repository.exportMetrics().reviewedDeliveries == 0)
            context.clock.advance(2)
            let new = context.ref(born: context.clock.now())
            _ = try context.observe("working", ref: new)
            context.clock.advance(8)
            _ = try context.observe("done", ref: new)
            #expect(try context.repository.exportMetrics().reviewedDeliveries == 0)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) {
                try context.repository.recordReviewedDelivery(agentRef: new, diffVersion: "v", diffIsEmpty: true)
            }
            #expect(try context.repository.load().interventions[0].isPending)
            let reviewed = try context.repository.recordReviewedDelivery(agentRef: new, diffVersion: "v", diffIsEmpty: false)
            #expect(reviewed.metrics.summary.reviewedDeliveries == 1)
            #expect(reviewed.metrics.summary.secondsToFirstReviewedDelivery == 8)
            #expect(!reviewed.interventions[0].isPending)
            #expect(try context.repository.recordReviewedDelivery(agentRef: new, diffVersion: "v2", diffIsEmpty: false)
                .metrics.summary.reviewedDeliveries == 1)
        }
    }

    @Test func visitDebounceIsThirtyMinutesButMidnightStillCountsAnActiveDay() throws {
        try withStore { context in
            context.clock.set(Date(timeIntervalSince1970: 1_800_057_590)) // 23:59:50 UTC
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.repository.recordVisit()
            context.clock.advance(20)
            let midnight = try context.repository.recordVisit()
            #expect(midnight.metrics.summary.visits == 1)
            #expect(midnight.metrics.summary.activeDays == 2)
            context.clock.advance(1_779)
            #expect(try context.repository.recordVisit().metrics.summary.visits == 1)
            context.clock.advance(1)
            #expect(try context.repository.recordVisit().metrics.summary.visits == 2)
        }
    }

    @Test func clockRollbackAndLongDurationsAreBoundedAndInvalidClockPreservesData() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.repository.recordVisit()
            let item = try #require(context.observe("paused", ref: ref).interventions.first)
            context.clock.advance(-3_600)
            let read = try context.repository.markRead(item.id)
            #expect(read.interventions[0].readAt == item.createdAt)
            #expect(read.metrics.summary.totalSecondsToOpen == 0)
            #expect(try context.repository.recordVisit().metrics.summary.visits == 1)
            context.clock.advance(100 * 24 * 60 * 60)
            let delivered = try context.repository.markInputDelivered(agentRef: ref, sentAt: context.clock.now())
            #expect(delivered.metrics.summary.totalSecondsToInput == DeliveryWorkflowRepository.maximumMeasuredSeconds)
            let before = try Data(contentsOf: context.repository.fileURL)
            context.clock.set(Date(timeIntervalSince1970: .nan))
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidClock) {
                try context.repository.recordVisit()
            }
            #expect(try Data(contentsOf: context.repository.fileURL) == before)
        }
    }

    @Test func staleInstancesMergeCommentsObservationsAndOptInState() throws {
        try withStore { context in
            let first = context.repository
            let second = context.repository
            #expect(try second.load().comments.isEmpty)
            let a = try first.addComment(agentRef: context.ref(), diffVersion: "a", line: 1, text: "A")
            _ = try first.setMetricsEnabled(true)
            let b = try second.addComment(agentRef: context.ref(2), diffVersion: "b", line: 1, text: "B")
            _ = try second.recordVisit()
            let result = try first.observe([.init(agentRef: context.ref(), state: "paused")])
            #expect(result.comments == [a, b])
            #expect(result.metrics.enabled)
            #expect(result.metrics.summary.visits == 1)
            #expect(result.interventions.count == 1)
        }
    }

    @Test func corruptUnsupportedAndSemanticallyInvalidStoresArePreserved() throws {
        try withStore { context in
            let repository = context.repository
            _ = try context.observe("paused", ref: context.ref())
            let valid = try Data(contentsOf: repository.fileURL)
            for corrupt in [Data("not json".utf8), try modifiedJSON(valid, key: "version", value: 99),
                            try duplicatedIntervention(valid)] {
                try corrupt.write(to: repository.fileURL)
                #expect(throws: (any Error).self) { try repository.load() }
                #expect(throws: (any Error).self) { try repository.setMetricsEnabled(true) }
                #expect(try Data(contentsOf: repository.fileURL) == corrupt)
            }
            try valid.write(to: repository.fileURL)
            #expect(try repository.setMetricsEnabled(true).metrics.enabled)
        }
    }

    @Test func occupiedLockRejectsReadersAndWritersAndReleasesAfterErrors() throws {
        try withStore { context in
            _ = try context.observe("paused", ref: context.ref())
            let repository = context.repository
            let before = try Data(contentsOf: repository.fileURL)
            let descriptor = open(repository.fileURL.path + ".lock", O_RDWR)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.busy) { try repository.load() }
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.busy) { try repository.recordVisit() }
            #expect(try Data(contentsOf: repository.fileURL) == before)
            #expect(flock(descriptor, LOCK_UN) == 0)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.notFound) { try repository.markRead(UUID()) }
            #expect(try repository.load().interventions.count == 1)
        }
    }

    @Test func atomicWriteFailurePreservesPriorSnapshotAndDoesNotAdvanceBaseline() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.observe("working", ref: ref)
            let before = try Data(contentsOf: context.repository.fileURL)
            let failing = DeliveryWorkflowRepository(fileURL: context.repository.fileURL, now: { context.clock.now() },
                writer: { _, _ in throw POSIXError(.ENOSPC) })
            #expect(throws: POSIXError.self) { try failing.observe([.init(agentRef: ref, state: "done")]) }
            #expect(try Data(contentsOf: context.repository.fileURL) == before)
            let recovered = try context.observe("done", ref: ref)
            #expect(recovered.interventions.count == 1)
            #expect(try context.observe("done", ref: ref).interventions == recovered.interventions)
        }
    }

    @Test func actualFilesystemFailuresAreReportedWithoutCreatingAStore() throws {
        try withStore { context in
            try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
            let parentFile = context.directory.appendingPathComponent("file")
            try Data("parent is a file".utf8).write(to: parentFile)
            let repository = DeliveryWorkflowRepository(engineHome: parentFile)
            #expect(throws: (any Error).self) { try repository.setMetricsEnabled(true) }
            #expect(try Data(contentsOf: parentFile) == Data("parent is a file".utf8))
            // A directory at the destination also fails the real bounded read before any mutation.
            try FileManager.default.createDirectory(at: context.repository.fileURL, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try context.repository.setMetricsEnabled(true) }
        }
    }

    @Test func realAtomicWritePermissionFailureKeepsPreviousJSONAndReleasesLock() throws {
        guard geteuid() != 0 else { return } // root bypasses directory write permissions
        try withStore { context in
            _ = try context.observe("paused", ref: context.ref())
            let before = try Data(contentsOf: context.repository.fileURL)
            #expect(chmod(context.directory.path, 0o500) == 0)
            defer { chmod(context.directory.path, 0o700) }
            #expect(throws: (any Error).self) { try context.repository.setMetricsEnabled(true) }
            #expect(try Data(contentsOf: context.repository.fileURL) == before)
            #expect(chmod(context.directory.path, 0o700) == 0)
            #expect(try context.repository.setMetricsEnabled(true).metrics.enabled)
        }
    }

    @Test func concurrentRepositoryInstancesNeverLoseAcknowledgedComments() async throws {
        let context = Context(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), clock: Clock())
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let comments = try await withThrowingTaskGroup(of: DeliveryComment.self) { group in
            for index in 0..<12 {
                group.addTask {
                    for _ in 0..<1_000 {
                        do {
                            return try context.repository.addComment(agentRef: context.ref(UInt32(index)),
                                diffVersion: "v", line: 1, text: "Comment \(index)")
                        } catch DeliveryWorkflowRepository.RepositoryError.busy {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    }
                    throw DeliveryWorkflowRepository.RepositoryError.busy
                }
            }
            var result: [DeliveryComment] = []
            for try await comment in group { result.append(comment) }
            return result
        }
        let loaded = try context.repository.load()
        #expect(loaded.comments.count == 12)
        #expect(Set(loaded.comments.map(\.id)) == Set(comments.map(\.id)))
    }

    @Test func inputAndEntityLimitsRejectWholeTransactions() throws {
        try withStore { context in
            let repository = context.repository
            let ref = context.ref()
            for (line, text, version) in [(0, "a", "v"), (1, "  ", "v"), (1, "a\u{1B}", "v"),
                (1, "a", ""), (1, String(repeating: "a", count: 8_193), "v")] {
                #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) {
                    try repository.addComment(agentRef: ref, diffVersion: version, line: line, text: text)
                }
            }
            let duplicate = DeliveryAgentObservation(agentRef: ref, state: "working")
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) { try repository.observe([duplicate, duplicate]) }
            var snapshot = DeliveryWorkflowSnapshot()
            snapshot.observedAgents = (0..<DeliveryWorkflowRepository.maximumRecords).map {
                .init(agentRef: .init(id: UInt32($0), createdAtMs: 1), state: "working")
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let full = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
            try full.write(to: repository.fileURL)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.limitExceeded) {
                try repository.observe([.init(agentRef: .init(id: 9_999, createdAtMs: 1), state: "paused")])
            }
            #expect(try Data(contentsOf: repository.fileURL) == full)
            let oversized = Data(repeating: 32, count: DeliveryWorkflowRepository.maximumFileBytes + 1)
            try oversized.write(to: repository.fileURL)
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.limitExceeded) { try repository.load() }
            #expect(try Data(contentsOf: repository.fileURL) == oversized)
        }
    }

    @Test func pullRequestObservationsPersistAndRejectOlderResultsAndCredentialURLs() throws {
        try withStore { context in
            let ref = context.ref()
            let first = link(ref: ref, observedAt: context.clock.now())
            _ = try context.repository.setPullRequestLink(first)
            #expect(try context.repository.load().pullRequestLinks == [first])
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) {
                try context.repository.setPullRequestLink(link(ref: ref, observedAt: context.clock.now(),
                    url: "https://token@github.com/example/repo/pull/12"))
            }
            #expect(throws: DeliveryWorkflowRepository.RepositoryError.invalidInput) {
                try context.repository.setPullRequestLink(link(ref: ref, observedAt: context.clock.now().addingTimeInterval(-1)))
            }
            context.clock.advance(1)
            let newer = link(ref: ref, observedAt: context.clock.now())
            #expect(try context.repository.setPullRequestLink(newer).pullRequestLinks == [newer])
            #expect(try context.repository.removePullRequestLink(agentRef: ref).pullRequestLinks.isEmpty)
        }
    }

    @Test func failingChecksDeduplicatePerPRHeadAndUnknownOrPendingCannotResolve() throws {
        try withStore { context in
            let ref = context.ref()
            let failed = link(ref: ref, observedAt: context.clock.now())
            #expect(failed.hasFailingChecks)
            let first = try context.repository.setPullRequestLink(failed)
            let occurrence = try #require(first.interventions.first)
            #expect(occurrence.kind == .checksFailed)
            #expect(occurrence.sourceVersion == failed.headOid)
            #expect(try context.repository.setPullRequestLink(failed).interventions == [occurrence])
            #expect(try context.observe("done", ref: ref).interventions == [occurrence])
            for checks: [DeliveryPullRequestCheck] in [[], [.init(name: "test", state: "IN_PROGRESS")],
                [.init(name: "test", state: "COMPLETED", conclusion: "UNKNOWN")]] {
                let pending = link(ref: ref, observedAt: context.clock.now(), checks: checks)
                #expect(try context.repository.setPullRequestLink(pending).interventions[0].isPending)
            }
            let passed = link(ref: ref, observedAt: context.clock.now(),
                checks: [.init(name: "test", state: "COMPLETED", conclusion: "SUCCESS")])
            let resolved = try context.repository.setPullRequestLink(passed)
            #expect(!resolved.interventions[0].isPending)
            #expect(resolved.interventions[0].resolvedAt != nil)
            #expect(resolved.interventions[0].reviewedAt == nil)
            // Without a check-run identity, the same PR/head is not treated as a new failure.
            #expect(try context.repository.setPullRequestLink(failed).interventions.count == 1)
        }
    }

    @Test func changingPRHeadResolvesOldFailureAndClosedPRDoesNotAddNewFailure() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.setPullRequestLink(link(ref: ref, observedAt: context.clock.now()))
            let next = link(ref: ref, observedAt: context.clock.now(), head: "next")
            let replaced = try context.repository.setPullRequestLink(next)
            #expect(replaced.interventions.count == 2)
            #expect(replaced.interventions[0].resolvedAt != nil)
            #expect(replaced.interventions[1].isPending)
            let closed = link(ref: ref, observedAt: context.clock.now(), head: "closed", state: "CLOSED")
            let closedSnapshot = try context.repository.setPullRequestLink(closed)
            #expect(closedSnapshot.interventions.count == 2)
            #expect(closedSnapshot.interventions.allSatisfy { !$0.isPending })
            _ = try context.repository.setPullRequestLink(link(ref: ref, observedAt: context.clock.now(), head: "third"))
            let removed = try context.repository.removePullRequestLink(agentRef: ref)
            #expect(removed.pullRequestLinks.isEmpty)
            #expect(removed.interventions[2].dismissedAt != nil)
            #expect(removed.interventions[2].resolvedAt == nil)
        }
    }

    @Test func exportIsStrictAggregateAllowlistWithoutStoredContentOrIdentifiers() throws {
        try withStore { context in
            let ref = context.ref()
            _ = try context.repository.setMetricsEnabled(true)
            _ = try context.repository.recordVisit()
            _ = try context.repository.addComment(agentRef: ref, diffVersion: "private-version", line: 5, text: "private-comment")
            _ = try context.repository.setPullRequestLink(link(ref: ref, observedAt: context.clock.now()))
            let data = try JSONEncoder().encode(context.repository.exportMetrics())
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys) == ["visits", "activeDays", "reviewedDeliveries", "openedInterventions",
                "deliveredInputs", "totalSecondsToOpen", "totalSecondsToInput"])
            #expect(object.values.allSatisfy { $0 is NSNumber })
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("private"))
            #expect(!text.contains("github"))
            #expect(!text.contains(String(ref.createdAtMs)))
        }
    }

    private func link(ref: DeliveryAgentReference, observedAt: Date,
                      url: String = "https://github.com/example/repo/pull/12", head: String = "abc", state: String = "OPEN",
                      checks: [DeliveryPullRequestCheck] = [.init(name: "test", state: "COMPLETED", conclusion: "FAILURE")]) -> DeliveryPullRequestLink {
        .init(agentRef: ref, repository: "example/repo", number: 12, url: url, title: "Example",
            branch: "review", headOid: head, localHeadOid: "def", state: state, diffVersion: "v",
            localDiffEmpty: false, checks: checks,
            observedAt: observedAt)
    }

    private func modifiedJSON(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func duplicatedIntervention(_ data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(object["interventions"] as? [Any])
        object["interventions"] = items + items
        return try JSONSerialization.data(withJSONObject: object)
    }
}
