import Foundation
import Testing
@testable import TramaCore

struct WorkspaceProjectGroupTests {
    private func agent(_ id: UInt32, project: String, session: String = "shared", cwd: String? = nil, archived: Bool = false) -> EngineAgent {
        EngineAgent(id: id, name: "Agent", kind: "terminal", state: "idle", session: session,
                    cwd: cwd ?? project, project: project, task: "Controlled", activity: "",
                    archived: archived, createdAtMs: UInt64(id))
    }

    @Test func sharedSessionShowsOnlyEachProjectsAgentsAndRetainsEmptyProjects() {
        let a = Project(name: "A", path: "/tmp/trama-group-a")
        let b = Project(name: "B", path: "/tmp/trama-group-b")
        let empty = Project(name: "Empty", path: "/tmp/trama-group-empty")
        let aa = agent(1, project: a.path), bb = agent(2, project: b.path)
        let otherSession = agent(3, project: a.path, session: "planning")
        let archived = agent(4, project: a.path, session: "archived", archived: true)
        let unknown = agent(5, project: "/tmp/trama-group-unknown")
        let groups = WorkspaceProjectGroup.groups(projects: [b, empty, a], agents: [aa, bb, otherSession, archived, unknown])
        #expect(groups.map(\.id) == [b.id, empty.id, a.id])
        #expect(groups[0].agents == [bb])
        #expect(groups[0].sessions == ["shared"])
        #expect(groups[1].agents.isEmpty && groups[1].sessions.isEmpty)
        #expect(groups[2].agents == [aa, otherSession])
        #expect(groups[2].sessions == ["planning", "shared"])
    }

    @Test func worktreeAndCanonicalAliasStayUnderTheOriginalProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-groups-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let alias = root.appendingPathComponent("alias")
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let project = Project(name: "Original", path: alias.path)
        let unrelated = Project(name: "Worktree", path: worktree.path)
        let record = agent(1, project: original.path, cwd: worktree.path)
        let groups = WorkspaceProjectGroup.groups(projects: [project, unrelated], agents: [record])
        #expect(groups[0].agents == [record])
        #expect(groups[1].agents.isEmpty)
    }
}
