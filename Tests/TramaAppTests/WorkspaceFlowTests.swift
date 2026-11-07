import Foundation
import Testing
import TramaCore
@testable import TramaApp

@MainActor
@Suite(.serialized)
struct WorkspaceFlowTests {
    private struct Fixture {
        let root: URL
        let projects: [Project]
        let agents: [EngineAgent]
        let repository: WorkspaceNavigationRepository
        let client: OctoEngineClient
        var response: URL { root.appendingPathComponent("response.json") }
        var request: URL { root.appendingPathComponent("request.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-workspace-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            projects = [Project(name: "Primeiro", path: root.appendingPathComponent("one").path),
                        Project(name: "Segundo", path: root.appendingPathComponent("two").path)]
            agents = projects.enumerated().map { index, project in
                EngineAgent(id: UInt32(index + 1), name: "agent-\(index)", kind: "codex", state: "idle",
                    session: "default", cwd: project.path, project: project.path, task: "Controlled", activity: "",
                    createdAtMs: UInt64(index + 100))
            }
            repository = WorkspaceNavigationRepository(fileURL: root.appendingPathComponent("navigation.json"))
            let executable = root.appendingPathComponent("fake-engine")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/sh\n/bin/cat > " + quote(root.appendingPathComponent("request.json").path) +
                "\n/bin/cat " + quote(root.appendingPathComponent("response.json").path) + "\n"
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            client = OctoEngineClient(executableURL: executable, homeURL: root.appendingPathComponent("engine"))
            try respond(with: agents)
        }

        func respond(with agents: [EngineAgent]) throws {
            let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineSessionList(agents: agents, sessions: ["default"])))
            try JSONSerialization.data(withJSONObject: ["protocol": 1, "ok": true, "result": result]).write(to: response)
        }
        func seedTabs() throws {
            try repository.update { state in
                for agent in agents.reversed() { try state.open(agent.deliveryReference!, projects: projects, agents: agents) }
            }
        }
        @MainActor func model() -> LiveWorkspaceModel {
            let value = LiveWorkspaceModel(client: client, navigationRepository: repository)
            value.configure(projects: projects)
            return value
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func projectSelectionBeforeFirstSuccessfulPollPreservesRestoredTabs() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.seedTabs()
        let original = try f.repository.load().openAgents
        let model = f.model()
        model.selectProject(f.projects[1].id)
        #expect(model.navigation.openAgents == original)
        #expect(try f.repository.load().openAgents == original)
        try Data("invalid response".utf8).write(to: f.response)
        await model.refresh()
        #expect(model.connectionError != nil)
        model.selectProject(f.projects[0].id)
        #expect(model.navigation.openAgents == original)
        #expect(try f.repository.load().openAgents == original)
    }

    @Test func aFailedRefreshNeverClosesAnOpenAgent() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let model = f.model()
        await model.refresh()
        model.open(f.agents[0])
        let reference = try #require(f.agents[0].deliveryReference)
        model.promptDrafts[reference] = "An unsent instruction"
        try Data("invalid".utf8).write(to: f.response)
        await model.refresh()
        #expect(model.navigation.selectedAgent == reference)
        #expect(model.navigation.openAgents == [reference])
        #expect(model.promptDrafts[reference] == "An unsent instruction")
    }

    @Test func closingATabDoesNotCallTheEngineOrDiscardItsDraft() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let model = f.model()
        await model.refresh()
        model.open(f.agents[0])
        let reference = try #require(f.agents[0].deliveryReference)
        model.promptDrafts[reference] = "Keep this draft"
        let requestBefore = try Data(contentsOf: f.request)
        model.close(reference)
        #expect(model.navigation.selectedAgent == nil)
        #expect(model.navigation.openAgents.isEmpty)
        #expect(model.agents[0].isAlive)
        #expect(model.promptDrafts[reference] == "Keep this draft")
        #expect(try Data(contentsOf: f.request) == requestBefore)
    }

    @Test func acknowledgedLaunchOpensOnlyItsExactIdentityAfterRefresh() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let model = f.model()
        let reference = try #require(f.agents[0].deliveryReference)
        model.didStart(reference, projectID: f.projects[0].id)
        #expect(model.pendingReference == reference)
        await model.refresh()
        #expect(model.pendingReference == nil)
        #expect(model.navigation.selectedAgent == reference)
        #expect(model.navigation.selectedProjectID == f.projects[0].id)
        #expect(model.navigation.mode == .workspace)
    }

    @Test func missingLaunchCanLeaveConnectingWithoutOpeningARecycledID() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let model = f.model()
        let oldReference = DeliveryAgentReference(id: f.agents[0].id, createdAtMs: 1)
        model.didStart(oldReference, projectID: f.projects[0].id)
        await model.refresh()
        #expect(model.pendingReference == oldReference)
        #expect(model.navigation.selectedAgent == nil)
        model.showOverview()
        #expect(model.pendingReference == nil)
        await model.refresh()
        #expect(model.navigation.selectedAgent == nil)
        #expect(model.navigation.mode == .board)
    }

    @Test func selectingAnotherProjectPreservesDraftsAndDoesNotSendOrStopAnything() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let model = f.model()
        await model.refresh()
        model.open(f.agents[0])
        let reference = try #require(f.agents[0].deliveryReference)
        model.promptDrafts[reference] = "Continue this agent"
        model.projectTaskDrafts[f.projects[0].id] = "Another new task"
        let requestBefore = try Data(contentsOf: f.request)
        model.selectProject(f.projects[1].id)
        #expect(model.navigation.selectedAgent == nil)
        #expect(model.promptDrafts[reference] == "Continue this agent")
        #expect(model.projectTaskDrafts[f.projects[0].id] == "Another new task")
        #expect(try Data(contentsOf: f.request) == requestBefore)
    }

    @Test func corruptNavigationDoesNotPreventExplicitProjectSelectionOrOverwriteTheFile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let corrupt = Data("preserve these invalid preferences".utf8)
        try corrupt.write(to: f.repository.fileURL)
        let model = f.model()
        model.selectProject(f.projects[0].id)
        #expect(model.navigation.selectedProjectID == f.projects[0].id)
        #expect(model.navigationError != nil)
        #expect(try Data(contentsOf: f.repository.fileURL) == corrupt)
        model.resetNavigation()
        #expect(model.navigationError == nil)
        #expect(try f.repository.load() == WorkspaceNavigationState())
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("navigation.json.backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == corrupt)
    }

    @Test func repeatingTheSameTaskGetsRecognizableDistinctNamesWithoutARefresh() {
        let first = AgentTaskName.make(task: "Corrigir cadastro de clientes")
        let second = AgentTaskName.make(task: "Corrigir cadastro de clientes", existingNames: [])
        #expect(first.hasPrefix("corrigir-cadastro-de-clientes-"))
        #expect(second.hasPrefix("corrigir-cadastro-de-clientes-"))
        #expect(first != second)
        for name in [first, second, AgentTaskName.make(task: "🧑‍💻"), AgentTaskName.make(task: String(repeating: "ção ", count: 100))] {
            #expect(!name.isEmpty && name.count <= 40)
            #expect(!name.contains("/") && !name.contains("\n"))
        }
    }

    @Test func composerAcceptsJoinedUnicodeTextAndRejectsTerminalControlSequences() {
        #expect(!AgentPromptComposer.hasTerminalControls("👨‍👩‍👧‍👦\nسلام\u{200c}دنیا\ttexto"))
        for text in ["\u{1b}[201~", "a\rcomando", "\u{3}", "\u{0085}"] {
            #expect(AgentPromptComposer.hasTerminalControls(text))
        }
    }
}
