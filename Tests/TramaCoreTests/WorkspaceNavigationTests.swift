import Foundation
import Darwin
import Testing
@testable import TramaCore

struct WorkspaceNavigationTests {
    private let a = Project(name: "A", path: "/tmp/trama-navigation-a")
    private let b = Project(name: "B", path: "/tmp/trama-navigation-b")

    private func agent(_ id: UInt32, project: Project, timestamp: UInt64? = 100,
                       state: String = "working", archived: Bool = false) -> EngineAgent {
        EngineAgent(id: id, name: "Agent", kind: "shell", state: state, session: "default",
                    cwd: "/tmp/worktrees/isolated", project: project.path, task: "private-task-sentinel",
                    activity: "private-output-sentinel", archived: archived, createdAtMs: timestamp)
    }

    private func ref(_ agent: EngineAgent) throws -> DeliveryAgentReference {
        DeliveryAgentReference(id: agent.id, createdAtMs: try #require(agent.createdAtMs))
    }

    private func withStore(_ body: (WorkspaceNavigationRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(WorkspaceNavigationRepository(fileURL: directory.appendingPathComponent("nested/navigation.json")))
    }

    @Test func projectSwitchKeepsOtherTabsAndClearsIncompatibleSelection() throws {
        let aa = agent(1, project: a), bb = agent(2, project: b)
        let ar = try ref(aa), br = try ref(bb)
        var state = WorkspaceNavigationState()
        #expect(state.mode == .board)
        #expect(state.selectedProjectID == nil)
        try state.open(ar, projects: [a, b], agents: [aa, bb])
        try state.open(br, projects: [a, b], agents: [aa, bb])
        #expect(state.selectedProjectID == b.id)
        #expect(state.mode == .workspace)
        try state.selectProject(a.id, projects: [a, b], agents: [aa, bb])
        #expect(state.selectedAgent == nil)
        #expect(state.openAgents == [ar, br])
        #expect(state.visibleOpenAgents(projects: [a, b], agents: [aa, bb]) == [aa])
        try state.selectProject(nil, projects: [a, b], agents: [aa, bb])
        #expect(state.visibleOpenAgents(projects: [a, b], agents: [bb, aa]) == [aa, bb])
        #expect(state.selectedProjectID == nil)
    }

    @Test func closeOnlyRemovesTheExactTabAndNeverSelectsAnother() throws {
        let aa = agent(1, project: a), bb = agent(2, project: a)
        let ar = try ref(aa), br = try ref(bb)
        var state = WorkspaceNavigationState()
        try state.open(ar, projects: [a], agents: [aa, bb])
        try state.open(br, projects: [a], agents: [aa, bb])
        state.close(ar, projects: [a], agents: [aa, bb])
        #expect(state.selectedAgent == br)
        state.close(DeliveryAgentReference(id: 2, createdAtMs: 999), projects: [a], agents: [aa, bb])
        #expect(state.openAgents == [br])
        state.close(br, projects: [a], agents: [aa, bb])
        #expect(state.openAgents.isEmpty)
        #expect(state.selectedAgent == nil)
        #expect(state.selectedProjectID == a.id)
        #expect(aa.isAlive && bb.isAlive)
    }

    @Test func recycledIDAndMissingTimestampCannotRestoreASelection() throws {
        let original = agent(1, project: a)
        let reference = try ref(original)
        for replacement in [agent(1, project: a, timestamp: 200), agent(1, project: a, timestamp: nil)] {
            var state = WorkspaceNavigationState()
            try state.open(reference, projects: [a], agents: [original])
            let before = state
            #expect(throws: WorkspaceNavigationState.NavigationError.agentUnavailable) {
                try state.open(reference, projects: [a], agents: [replacement])
            }
            #expect(state == before)
            state.reconcile(projects: [a], agents: [replacement])
            #expect(state.openAgents.isEmpty)
            #expect(state.selectedAgent == nil)
        }
    }

    @Test func snapshotRemovalNeverChoosesAnotherAgentOrProject() throws {
        let aa = agent(1, project: a), bb = agent(2, project: b)
        var state = WorkspaceNavigationState()
        try state.open(try ref(aa), projects: [a, b], agents: [aa, bb])
        try state.open(try ref(bb), projects: [a, b], agents: [aa, bb])
        state.reconcile(projects: [a], agents: [aa, bb])
        #expect(state.selectedProjectID == nil)
        #expect(state.selectedAgent == nil)
        #expect(state.openAgents == [try ref(aa)])
        state.reconcile(projects: [a], agents: [])
        #expect(state.openAgents.isEmpty)
    }

    @Test func archivedExitedAndDoneRecordsRemainAvailableWithoutInferringSuccess() throws {
        for status in ["done", "exited", "lost"] {
            let record = agent(1, project: a, state: status, archived: true)
            var state = WorkspaceNavigationState()
            try state.open(try ref(record), projects: [a], agents: [record])
            state.reconcile(projects: [a], agents: [record])
            #expect(state.selectedAgent == (try ref(record)))
            #expect(state.visibleOpenAgents(projects: [a], agents: [record]) == [record])
        }
    }

    @Test func worktreeUsesCanonicalProjectAndNotWorkingDirectory() throws {
        try withStore { repository in
            let root = repository.fileURL.deletingLastPathComponent()
            let real = root.appendingPathComponent("real")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            let project = Project(name: "Local", path: alias.path + "/./")
            let record = agent(1, project: Project(name: "Canonical", path: real.path))
            #expect(WorkspaceNavigationState.matches(agent: record, project: project))
            var state = WorkspaceNavigationState()
            try state.open(try ref(record), projects: [project], agents: [record])
            #expect(state.selectedProjectID == project.id)
            #expect(!WorkspaceNavigationState.matches(agent: record, project: Project(name: "Cwd", path: record.cwd)))
            #expect(!WorkspaceNavigationState.matches(agent: record, project: Project(name: "Relative", path: "relative")))
        }
    }

    @Test func unavailableAndAmbiguousTargetsLeaveStateUntouched() throws {
        let aa = agent(1, project: a)
        var state = WorkspaceNavigationState()
        let before = state
        #expect(throws: WorkspaceNavigationState.NavigationError.projectUnavailable) {
            try state.selectProject(UUID(), projects: [a], agents: [aa])
        }
        #expect(throws: WorkspaceNavigationState.NavigationError.projectUnavailable) {
            try state.open(try ref(aa), projects: [b], agents: [aa])
        }
        #expect(throws: WorkspaceNavigationState.NavigationError.agentUnavailable) {
            try state.open(try ref(aa), projects: [a], agents: [aa, aa])
        }
        #expect(state == before)
    }

    @Test func modesAndRepeatedOpenPreserveTabOrder() throws {
        let aa = agent(1, project: a), bb = agent(2, project: a)
        var state = WorkspaceNavigationState()
        try state.open(try ref(aa), projects: [a], agents: [aa, bb])
        try state.open(try ref(bb), projects: [a], agents: [aa, bb])
        state.setMode(.list)
        #expect(state.selectedAgent == (try ref(bb)))
        #expect(state.openAgents == [try ref(aa), try ref(bb)])
        try state.open(try ref(aa), projects: [a], agents: [aa, bb])
        #expect(state.mode == .workspace)
        #expect(state.openAgents == [try ref(aa), try ref(bb)])
    }

    @Test func tabLimitRejectsTheSixtyFifthWithoutEviction() throws {
        let agents = (1...65).map { agent(UInt32($0), project: a) }
        var state = WorkspaceNavigationState()
        for record in agents.prefix(64) { try state.open(try ref(record), projects: [a], agents: agents) }
        let before = state
        #expect(throws: WorkspaceNavigationState.NavigationError.limitExceeded) {
            try state.open(try ref(agents[64]), projects: [a], agents: agents)
        }
        #expect(state == before)
        try state.open(try ref(agents[0]), projects: [a], agents: agents)
        #expect(state.openAgents.count == 64)
    }

    @Test func invalidConstructedAndDecodedStatesAreRejected() throws {
        let reference = DeliveryAgentReference(id: 1, createdAtMs: 100)
        #expect(throws: WorkspaceNavigationState.NavigationError.invalidState) {
            try WorkspaceNavigationState(selectedProjectID: nil, openAgents: [reference, reference])
        }
        #expect(throws: WorkspaceNavigationState.NavigationError.invalidState) {
            try WorkspaceNavigationState(selectedProjectID: nil, selectedAgent: reference)
        }
        let json = Data(#"{"mode":"workspace","openAgents":[],"selectedAgent":{"id":1,"createdAtMs":100}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkspaceNavigationState.self, from: json) }
    }

    @Test func firstRunAndRestorePersistOnlyIdentitiesAndView() throws {
        try withStore { repository in
            #expect(try repository.load() == WorkspaceNavigationState())
            #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
            let record = agent(7, project: a)
            let saved = try repository.update { state in
                try state.open(try ref(record), projects: [a], agents: [record])
                state.setMode(.list)
            }
            let restored = try WorkspaceNavigationRepository(fileURL: repository.fileURL).load()
            #expect(restored == saved)
            #expect(restored.selectedProjectID == a.id)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.fileURL)) as? [String: Any]
            #expect(Set(try #require(json).keys) == ["version", "state"])
            let fields = try #require(json?["state"] as? [String: Any])
            #expect(Set(fields.keys) == ["selectedProjectID", "selectedAgent", "openAgents", "mode"])
            let text = try String(contentsOf: repository.fileURL, encoding: .utf8)
            #expect(!text.contains(record.task) && !text.contains(record.activity) && !text.contains(a.path))
        }
    }

    @Test func staleInstancesApplyIntentToLatestDiskSnapshot() throws {
        try withStore { first in
            let second = WorkspaceNavigationRepository(fileURL: first.fileURL)
            #expect(try second.load().openAgents.isEmpty)
            let aa = agent(1, project: a), bb = agent(2, project: b)
            try first.update { try $0.open(try ref(aa), projects: [a, b], agents: [aa, bb]) }
            let merged = try second.update { try $0.open(try ref(bb), projects: [a, b], agents: [aa, bb]) }
            #expect(merged.openAgents == [try ref(aa), try ref(bb)])
            #expect(try first.load() == merged)
        }
    }

    @Test func malformedFutureAndOversizedStoresArePreservedUntilExplicitReset() throws {
        try withStore { repository in
            try repository.reset()
            let samples = [Data("invalid json".utf8), Data(#"{"version":2}"#.utf8),
                           Data(#"{"version":1,"state":{"mode":"board","openAgents":[{"id":1}]}}"#.utf8),
                           Data(repeating: 32, count: WorkspaceNavigationRepository.maximumFileBytes + 1)]
            for invalid in samples {
                try invalid.write(to: repository.fileURL)
                #expect(throws: WorkspaceNavigationRepository.RepositoryError.self) { try repository.load() }
                #expect(throws: WorkspaceNavigationRepository.RepositoryError.self) { try repository.update { $0.setMode(.list) } }
                #expect(try Data(contentsOf: repository.fileURL) == invalid)
            }
            let corrupt = Data("corruption to preserve".utf8)
            try corrupt.write(to: repository.fileURL)
            #expect(try repository.reset() == WorkspaceNavigationState())
            let backups = try FileManager.default.contentsOfDirectory(at: repository.fileURL.deletingLastPathComponent(),
                                                                      includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("navigation.json.backup-") }
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: #require(backups.first)) == corrupt)
            #expect(try repository.load() == WorkspaceNavigationState())
        }
    }

    @Test func lockContentionRejectsLoadUpdateAndResetWithoutChangingBytes() throws {
        try withStore { repository in
            try repository.reset()
            let before = try Data(contentsOf: repository.fileURL)
            let descriptor = Darwin.open(repository.fileURL.path + ".lock", O_RDWR)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            #expect(throws: WorkspaceNavigationRepository.RepositoryError.busy) { try repository.load() }
            #expect(throws: WorkspaceNavigationRepository.RepositoryError.busy) { try repository.update { $0.setMode(.list) } }
            #expect(throws: WorkspaceNavigationRepository.RepositoryError.busy) { try repository.reset() }
            #expect(try Data(contentsOf: repository.fileURL) == before)
            #expect(flock(descriptor, LOCK_UN) == 0)
            #expect(try repository.update { $0.setMode(.list) }.mode == .list)
        }
    }

    @Test func thrownIntentAndAtomicWriteFailureDoNotPublishChanges() throws {
        try withStore { repository in
            try repository.reset()
            let before = try Data(contentsOf: repository.fileURL)
            #expect(throws: POSIXError.self) {
                try repository.update { state in
                    state.setMode(.list)
                    throw POSIXError(.ECANCELED)
                }
            }
            let failing = WorkspaceNavigationRepository(fileURL: repository.fileURL, writer: { _, _ in throw POSIXError(.ENOSPC) })
            #expect(throws: POSIXError.self) { try failing.update { $0.setMode(.list) } }
            #expect(try Data(contentsOf: repository.fileURL) == before)
            #expect(try repository.load().mode == .board)
            #expect(try repository.update { $0.setMode(.list) }.mode == .list)
        }
    }

    @Test func realFilesystemFailuresAreReportedWithoutDestroyingObstacles() throws {
        try withStore { repository in
            let parent = repository.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
            let obstacle = Data("not a directory".utf8)
            try obstacle.write(to: parent)
            #expect(throws: (any Error).self) { try repository.load() }
            #expect(throws: (any Error).self) { try repository.update { $0.setMode(.list) } }
            #expect(try Data(contentsOf: parent) == obstacle)
        }
    }

    @Test func realAtomicWriteFailureKeepsPreviousPreferences() throws {
        try withStore { repository in
            // A real atomic write cannot create its replacement in a non-writable directory.
            guard geteuid() != 0 else { return }
            try repository.reset()
            let before = try Data(contentsOf: repository.fileURL)
            let directory = repository.fileURL.deletingLastPathComponent()
            #expect(chmod(directory.path, 0o500) == 0)
            defer { chmod(directory.path, 0o700) }
            #expect(throws: (any Error).self) { try repository.update { $0.setMode(.list) } }
            #expect(try Data(contentsOf: repository.fileURL) == before)
            #expect(try repository.load().mode == .board)
        }
    }
}
