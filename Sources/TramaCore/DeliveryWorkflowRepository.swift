import Foundation
import Darwin

/// Bounded local storage. Every read/mutation locks the stable sidecar inode and re-reads JSON.
/// A failed write never publishes an in-memory snapshot or replaces a malformed store.
public struct DeliveryWorkflowRepository: Sendable {
    public let fileURL: URL
    public static let maximumFileBytes = 8 * 1_024 * 1_024
    public static let maximumRecords = 4_096
    public static let maximumComments = 1_024
    public static let maximumCommentBytes = 8_192
    public static let visitDebounceSeconds: TimeInterval = 30 * 60
    public static let maximumMeasuredSeconds: TimeInterval = 30 * 24 * 60 * 60

    private let now: @Sendable () -> Date
    private let writer: @Sendable (Data, URL) throws -> Void

    public init(engineHome: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(fileURL: engineHome.appendingPathComponent("trama-delivery-workflow.json"), now: now)
    }

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(fileURL: fileURL, now: now, writer: { try $0.write(to: $1, options: .atomic) })
    }

    // Fault injection verifies the same transaction path used by real writes.
    init(fileURL: URL, now: @escaping @Sendable () -> Date,
         writer: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.now = now
        self.writer = writer
    }

    public func load() throws -> DeliveryWorkflowSnapshot {
        try withLock { try read() }
    }

    /// Call only with a complete, successful engine poll. Failed polls do not advance the baseline.
    @discardableResult
    public func observe(_ agents: [DeliveryAgentObservation]) throws -> DeliveryWorkflowSnapshot {
        guard agents.count <= Self.maximumRecords,
              Set(agents.map(\.agentRef)).count == agents.count else { throw RepositoryError.invalidInput }
        return try mutate { snapshot, date in
            for agent in agents where Self.knownStates.contains(agent.state) {
                let previous = snapshot.observedAgents.firstIndex { $0.agentRef == agent.agentRef }
                let previousState = previous.map { snapshot.observedAgents[$0].state }
                for index in snapshot.interventions.indices {
                    let item = snapshot.interventions[index]
                    guard item.agentRef == agent.agentRef, item.resolvedAt == nil else { continue }
                    let resolves: Bool
                    switch item.kind {
                    case .paused: resolves = ["idle", "working", "done", "exited"].contains(agent.state)
                    case .lost: resolves = ["idle", "working", "paused", "done", "exited"].contains(agent.state)
                    case .reviewAvailable, .checksFailed: resolves = false
                    }
                    if resolves { snapshot.interventions[index].resolvedAt = date }
                }
                let kind: DeliveryIntervention.Kind?
                switch agent.state {
                case "paused": kind = .paused
                case "lost": kind = .lost
                case "done" where previousState != nil && previousState != "done": kind = .reviewAvailable
                default: kind = nil
                }
                if let kind, previousState != agent.state,
                   kind == .reviewAvailable || !snapshot.interventions.contains(where: {
                       $0.agentRef == agent.agentRef && $0.kind == kind && $0.isPending
                   }) {
                    snapshot.interventions.append(DeliveryIntervention(
                        id: UUID(), agentRef: agent.agentRef, kind: kind, createdAt: date,
                        sourceVersion: nil, sourceRepository: nil, sourcePullRequestNumber: nil
                    ))
                }
                if let previous {
                    snapshot.observedAgents[previous].state = agent.state
                } else {
                    snapshot.observedAgents.append(.init(agentRef: agent.agentRef, state: agent.state))
                }
            }
        }
    }

    @discardableResult
    public func markRead(_ id: UUID) throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            guard let index = snapshot.interventions.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound
            }
            guard snapshot.interventions[index].readAt == nil else { return }
            snapshot.interventions[index].readAt = date
            if let start = snapshot.metrics.enabledAt, snapshot.metrics.enabled,
               snapshot.interventions[index].createdAt >= start {
                Self.increment(&snapshot.metrics.summary.openedInterventions)
                snapshot.metrics.summary.totalSecondsToOpen += Self.elapsed(
                    from: snapshot.interventions[index].createdAt, to: date
                )
            }
        }
    }

    @discardableResult
    public func dismissIntervention(_ id: UUID) throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            guard let index = snapshot.interventions.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound
            }
            if snapshot.interventions[index].dismissedAt == nil {
                snapshot.interventions[index].dismissedAt = date
            }
        }
    }

    /// Capture `sentAt` before RPC; call only after a successful delivery, never after timeout.
    /// The input's contents are intentionally absent from this API and from persistence.
    @discardableResult
    public func markInputDelivered(agentRef: DeliveryAgentReference, sentAt: Date) throws -> DeliveryWorkflowSnapshot {
        guard Self.validDate(sentAt) else { throw RepositoryError.invalidInput }
        let sentAt = Self.millisecondDate(sentAt)
        return try mutate { snapshot, date in
            guard sentAt <= date else { throw RepositoryError.invalidInput }
            guard let index = snapshot.interventions.lastIndex(where: {
                $0.agentRef == agentRef && $0.kind == .paused && $0.createdAt <= sentAt &&
                ($0.resolvedAt.map { $0 >= sentAt } ?? true) &&
                ($0.dismissedAt.map { $0 >= sentAt } ?? true)
            }), snapshot.interventions[index].inputDeliveredAt == nil else { return }
            // `sentAt` prevents attaching an old RPC to a newer pause. The acknowledgment
            // is observed now; using its start time would understate time to delivered input.
            snapshot.interventions[index].inputDeliveredAt = date
            if let start = snapshot.metrics.enabledAt, snapshot.metrics.enabled,
               snapshot.interventions[index].createdAt >= start {
                Self.increment(&snapshot.metrics.summary.deliveredInputs)
                snapshot.metrics.summary.totalSecondsToInput += Self.elapsed(
                    from: snapshot.interventions[index].createdAt, to: date
                )
            }
        }
    }

    @discardableResult
    public func setMetricsEnabled(_ enabled: Bool) throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            guard snapshot.metrics.enabled != enabled else { return }
            snapshot.metrics = DeliveryMetrics()
            snapshot.metrics.enabled = enabled
            snapshot.metrics.enabledAt = enabled ? date : nil
        }
    }

    @discardableResult
    public func recordVisit() throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            guard snapshot.metrics.enabled else { return }
            let day = Self.utcDay(date)
            if !snapshot.metrics.activeDates.contains(day) {
                snapshot.metrics.activeDates.append(day)
                snapshot.metrics.summary.activeDays = snapshot.metrics.activeDates.count
            }
            if let previous = snapshot.metrics.lastVisitAt,
               date.timeIntervalSince(previous) < Self.visitDebounceSeconds { return }
            Self.increment(&snapshot.metrics.summary.visits)
            snapshot.metrics.lastVisitAt = date
        }
    }

    /// An explicit local review action on a nonempty exact diff, not test/CI/provider success.
    @discardableResult
    public func recordReviewedDelivery(agentRef: DeliveryAgentReference, diffVersion: String,
                                       diffIsEmpty: Bool) throws -> DeliveryWorkflowSnapshot {
        guard !diffIsEmpty, Self.validVersion(diffVersion) else { throw RepositoryError.invalidInput }
        return try mutate { snapshot, date in
            for index in snapshot.interventions.indices where
                snapshot.interventions[index].agentRef == agentRef &&
                snapshot.interventions[index].kind == .reviewAvailable && snapshot.interventions[index].isPending {
                snapshot.interventions[index].reviewedAt = date
            }
            guard snapshot.metrics.enabled, let start = snapshot.metrics.enabledAt,
                  Double(agentRef.createdAtMs) >= start.timeIntervalSince1970 * 1_000,
                  Double(agentRef.createdAtMs) <= date.timeIntervalSince1970 * 1_000,
                  !snapshot.metrics.reviewedAgents.contains(agentRef) else { return }
            snapshot.metrics.reviewedAgents.append(agentRef)
            Self.increment(&snapshot.metrics.summary.reviewedDeliveries)
            if snapshot.metrics.summary.secondsToFirstReviewedDelivery == nil {
                snapshot.metrics.summary.secondsToFirstReviewedDelivery = Self.elapsed(
                    from: Date(timeIntervalSince1970: Double(agentRef.createdAtMs) / 1_000), to: date
                )
            }
        }
    }

    public func addComment(agentRef: DeliveryAgentReference, diffVersion: String,
                           line: Int, text: String) throws -> DeliveryComment {
        guard Self.validVersion(diffVersion), (1...1_000_000).contains(line), Self.validText(text) else {
            throw RepositoryError.invalidInput
        }
        let snapshot = try mutate { snapshot, date in
            snapshot.comments.append(DeliveryComment(id: UUID(), agentRef: agentRef,
                diffVersion: diffVersion, line: line, text: text, createdAt: date, updatedAt: date))
        }
        // The transaction appended exactly one comment or threw before publishing it.
        return snapshot.comments[snapshot.comments.count - 1]
    }

    @discardableResult
    public func updateComment(_ id: UUID, text: String) throws -> DeliveryWorkflowSnapshot {
        guard Self.validText(text) else { throw RepositoryError.invalidInput }
        return try mutate { snapshot, date in
            guard let index = snapshot.comments.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound
            }
            guard snapshot.comments[index].text != text else { return }
            snapshot.comments[index].text = text
            snapshot.comments[index].updatedAt = Self.nextRevisionDate(after: snapshot.comments[index].updatedAt, now: date)
            snapshot.comments[index].sentAt = nil
        }
    }

    @discardableResult
    public func resolveComment(_ id: UUID) throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            guard let index = snapshot.comments.firstIndex(where: { $0.id == id }) else {
                throw RepositoryError.notFound
            }
            if snapshot.comments[index].resolvedAt == nil {
                snapshot.comments[index].resolvedAt = date
                snapshot.comments[index].updatedAt = Self.nextRevisionDate(after: snapshot.comments[index].updatedAt, now: date)
            }
        }
    }

    /// Pass the exact snapshots acknowledged by sendReview. A concurrent edit rejects the entire batch.
    @discardableResult
    public func markCommentsSent(_ comments: [DeliveryComment]) throws -> DeliveryWorkflowSnapshot {
        guard (1...32).contains(comments.count), Set(comments.map(\.id)).count == comments.count,
              Set(comments.map(\.agentRef)).count == 1, Set(comments.map(\.diffVersion)).count == 1 else {
            throw RepositoryError.invalidInput
        }
        return try mutate { snapshot, date in
            var indices: [Int] = []
            for comment in comments {
                guard let index = snapshot.comments.firstIndex(where: { $0.id == comment.id }),
                      snapshot.comments[index] == comment, comment.resolvedAt == nil else {
                    throw RepositoryError.staleComment
                }
                indices.append(index)
            }
            for index in indices where snapshot.comments[index].sentAt == nil {
                snapshot.comments[index].sentAt = date
            }
        }
    }

    @discardableResult
    public func setPullRequestLink(_ link: DeliveryPullRequestLink) throws -> DeliveryWorkflowSnapshot {
        guard Self.validLink(link) else { throw RepositoryError.invalidInput }
        return try mutate { snapshot, date in
            if let index = snapshot.pullRequestLinks.firstIndex(where: { $0.agentRef == link.agentRef }) {
                guard snapshot.pullRequestLinks[index].observedAt <= link.observedAt else {
                    throw RepositoryError.invalidInput
                }
                snapshot.pullRequestLinks[index] = link
            } else {
                snapshot.pullRequestLinks.append(link)
            }
            let closed = ["CLOSED", "MERGED"].contains(link.state.uppercased())
            for index in snapshot.interventions.indices {
                let item = snapshot.interventions[index]
                guard item.agentRef == link.agentRef, item.kind == .checksFailed, item.resolvedAt == nil else { continue }
                let superseded = item.sourceRepository != link.repository ||
                    item.sourcePullRequestNumber != link.number || item.sourceVersion != link.headOid
                if superseded || closed || (link.hasConclusiveChecks && !link.hasFailingChecks) {
                    snapshot.interventions[index].resolvedAt = date
                }
            }
            // The RPC supplies no check-run identity: deduplicate this PR/head even after dismissal.
            if link.hasFailingChecks && !closed && !snapshot.interventions.contains(where: {
                $0.agentRef == link.agentRef && $0.kind == .checksFailed && $0.sourceRepository == link.repository &&
                $0.sourcePullRequestNumber == link.number && $0.sourceVersion == link.headOid
            }) {
                snapshot.interventions.append(DeliveryIntervention(id: UUID(), agentRef: link.agentRef,
                    kind: .checksFailed, createdAt: date, sourceVersion: link.headOid,
                    sourceRepository: link.repository, sourcePullRequestNumber: link.number))
            }
        }
    }

    @discardableResult
    public func removePullRequestLink(agentRef: DeliveryAgentReference) throws -> DeliveryWorkflowSnapshot {
        try mutate { snapshot, date in
            snapshot.pullRequestLinks.removeAll { $0.agentRef == agentRef }
            for index in snapshot.interventions.indices where snapshot.interventions[index].agentRef == agentRef &&
                snapshot.interventions[index].kind == .checksFailed && snapshot.interventions[index].isPending {
                snapshot.interventions[index].dismissedAt = date
            }
        }
    }

    public func exportMetrics() throws -> DeliveryMetricsExport { try load().metrics.summary }

    private static let knownStates: Set<String> = ["idle", "working", "paused", "done", "lost", "exited"]

    private func mutate(_ body: (inout DeliveryWorkflowSnapshot, Date) throws -> Void) throws -> DeliveryWorkflowSnapshot {
        try withLock {
            var snapshot = try read()
            let before = snapshot
            let clockDate = now()
            guard Self.validDate(clockDate) else { throw RepositoryError.invalidClock }
            // A wall-clock correction never moves persisted event times backwards.
            let date = max(Self.millisecondDate(clockDate), snapshot.lastTimestamp ?? Self.millisecondDate(clockDate))
            try body(&snapshot, date)
            if snapshot == before { return snapshot }
            snapshot.lastTimestamp = max(date, snapshot.comments.map(\.updatedAt).max() ?? date)
            try validate(snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(snapshot)
            guard data.count <= Self.maximumFileBytes else { throw RepositoryError.limitExceeded }
            try writer(data, fileURL)
            return snapshot
        }
    }

    private func read() throws -> DeliveryWorkflowSnapshot {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return DeliveryWorkflowSnapshot()
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw RepositoryError.limitExceeded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DeliveryWorkflowSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw RepositoryError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func validate(_ snapshot: DeliveryWorkflowSnapshot) throws {
        guard snapshot.version == 1 else { throw RepositoryError.unsupportedVersion(snapshot.version) }
        guard snapshot.interventions.count <= Self.maximumRecords,
              snapshot.observedAgents.count <= Self.maximumRecords,
              snapshot.comments.count <= Self.maximumComments,
              snapshot.pullRequestLinks.count <= Self.maximumRecords,
              snapshot.metrics.activeDates.count <= Self.maximumRecords,
              snapshot.metrics.reviewedAgents.count <= Self.maximumRecords else { throw RepositoryError.limitExceeded }
        guard Set(snapshot.interventions.map(\.id)).count == snapshot.interventions.count,
              Set(snapshot.comments.map(\.id)).count == snapshot.comments.count,
              Set(snapshot.observedAgents.map(\.agentRef)).count == snapshot.observedAgents.count,
              Set(snapshot.pullRequestLinks.map(\.agentRef)).count == snapshot.pullRequestLinks.count,
              Set(snapshot.metrics.reviewedAgents).count == snapshot.metrics.reviewedAgents.count,
              snapshot.observedAgents.allSatisfy({ Self.knownStates.contains($0.state) }),
              snapshot.lastTimestamp.map(Self.validDate) ?? true else { throw RepositoryError.invalidData }
        for item in snapshot.interventions {
            guard Self.validDate(item.createdAt),
                  [item.readAt, item.inputDeliveredAt, item.resolvedAt, item.dismissedAt, item.reviewedAt]
                    .allSatisfy({ $0.map { Self.validDate($0) && $0 >= item.createdAt } ?? true }),
                  item.kind == .paused || item.inputDeliveredAt == nil,
                  item.kind == .reviewAvailable || item.reviewedAt == nil,
                  item.kind != .reviewAvailable || item.resolvedAt == nil else { throw RepositoryError.invalidData }
            if item.kind == .checksFailed {
                guard let source = item.sourceVersion, Self.validVersion(source),
                      let repository = item.sourceRepository, (1...256).contains(repository.utf8.count),
                      let number = item.sourcePullRequestNumber, number > 0 else { throw RepositoryError.invalidData }
            } else if item.sourceVersion != nil || item.sourceRepository != nil || item.sourcePullRequestNumber != nil {
                throw RepositoryError.invalidData
            }
        }
        for item in snapshot.comments {
            guard Self.validText(item.text), Self.validVersion(item.diffVersion), (1...1_000_000).contains(item.line),
                  Self.validDate(item.createdAt), Self.validDate(item.updatedAt), item.updatedAt >= item.createdAt,
                  [item.sentAt, item.resolvedAt].allSatisfy({ $0.map { Self.validDate($0) && $0 >= item.createdAt } ?? true })
            else { throw RepositoryError.invalidData }
        }
        guard snapshot.pullRequestLinks.allSatisfy(Self.validLink) else { throw RepositoryError.invalidData }
        let metrics = snapshot.metrics
        let summary = metrics.summary
        guard metrics.enabled == (metrics.enabledAt != nil), metrics.enabledAt.map(Self.validDate) ?? true,
              metrics.lastVisitAt.map(Self.validDate) ?? true,
              Set(metrics.activeDates).count == metrics.activeDates.count,
              metrics.activeDates.allSatisfy({ $0.utf8.count == 10 && $0.allSatisfy { $0.isNumber || $0 == "-" } }),
              summary.activeDays == metrics.activeDates.count,
              summary.reviewedDeliveries == metrics.reviewedAgents.count,
              [summary.visits, summary.activeDays, summary.reviewedDeliveries, summary.openedInterventions,
               summary.deliveredInputs].allSatisfy({ $0 >= 0 }),
              [summary.totalSecondsToOpen, summary.totalSecondsToInput, summary.secondsToFirstReviewedDelivery ?? 0]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              metrics.enabled || metrics == DeliveryMetrics() else { throw RepositoryError.invalidData }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(date.timeIntervalSince1970)
    }

    private static func millisecondDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
    }

    private static func nextRevisionDate(after previous: Date, now: Date) -> Date {
        max(now, Date(timeIntervalSince1970: (floor(previous.timeIntervalSince1970 * 1_000) + 1) / 1_000))
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256 &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumCommentBytes &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }

    private static func validLink(_ link: DeliveryPullRequestLink) -> Bool {
        let parts = link.repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.unicodeScalars.allSatisfy { allowed.contains($0) } }),
              link.repository.utf8.count <= 256, link.number > 0,
              link.url == "https://github.com/\(link.repository)/pull/\(link.number)",
              validDate(link.observedAt), validVersion(link.diffVersion), validVersion(link.headOid),
              validVersion(link.localHeadOid), link.checks.count <= 256,
              [link.title, link.branch, link.headOid, link.localHeadOid, link.state].allSatisfy({
                  $0.utf8.count <= 1_024 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }), link.checks.allSatisfy({ check in
                  [check.name, check.state, check.conclusion ?? ""].allSatisfy {
                      $0.utf8.count <= 1_024 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                  }
              }) else { return false }
        return true
    }

    private static func elapsed(from: Date, to: Date) -> TimeInterval {
        min(maximumMeasuredSeconds, max(0, to.timeIntervalSince(from)))
    }

    private static func increment(_ value: inout Int) { if value < Int.max { value += 1 } }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public enum RepositoryError: LocalizedError, Equatable {
        case busy, invalidInput, invalidData, invalidClock, notFound, staleComment, limitExceeded
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .busy: "Outra instância está atualizando a inbox. Tente novamente."
            case .invalidInput: "Dados de revisão inválidos. Atualize a revisão e tente novamente."
            case .invalidData: "O arquivo da inbox contém dados inválidos e foi preservado."
            case .invalidClock: "O relógio local não permite registrar este evento."
            case .notFound: "O item não está mais disponível. Atualize a inbox."
            case .staleComment: "Um comentário mudou durante o envio. Revise a versão local antes de reenviar."
            case .limitExceeded: "O armazenamento local da inbox atingiu seu limite. Os dados foram preservados."
            case .unsupportedVersion(let version): "A versão \(version) da inbox ainda não é suportada."
            }
        }
    }
}
