import Foundation

public enum WorkspaceNavigationMode: String, Codable, CaseIterable, Sendable {
    case workspace, board, list
}

/// UI preferences only. Agent identity always includes its creation timestamp.
/// Supply complete, successful engine snapshots; a failed poll must not reconcile this state.
public struct WorkspaceNavigationState: Codable, Equatable, Sendable {
    public static let maximumOpenAgents = 64

    /// nil means all registered projects, with no automatic project selection.
    public private(set) var selectedProjectID: UUID?
    public private(set) var openAgents: [DeliveryAgentReference]
    public private(set) var selectedAgent: DeliveryAgentReference?
    public private(set) var mode: WorkspaceNavigationMode

    public init() {
        selectedProjectID = nil
        openAgents = []
        selectedAgent = nil
        mode = .board
    }

    public init(selectedProjectID: UUID?, openAgents: [DeliveryAgentReference] = [],
                selectedAgent: DeliveryAgentReference? = nil, mode: WorkspaceNavigationMode = .board) throws {
        self.selectedProjectID = selectedProjectID
        self.openAgents = openAgents
        self.selectedAgent = selectedAgent
        self.mode = mode
        try validate()
    }

    public mutating func selectProject(_ id: UUID?, projects: [Project], agents: [EngineAgent]) throws {
        guard id == nil || projects.contains(where: { $0.id == id }) else {
            throw NavigationError.projectUnavailable
        }
        selectedProjectID = id
        reconcile(projects: projects, agents: agents)
    }

    /// Opens a tab, including exited/archived history, without starting or controlling a process.
    public mutating func open(_ reference: DeliveryAgentReference, projects: [Project], agents: [EngineAgent]) throws {
        guard let agent = Self.exactAgent(reference, agents: agents) else {
            throw NavigationError.agentUnavailable
        }
        let matchingProjects = projects.filter { Self.matches(agent: agent, project: $0) }
        guard matchingProjects.count == 1, let project = matchingProjects.first else {
            throw NavigationError.projectUnavailable
        }
        var updated = self
        updated.reconcile(projects: projects, agents: agents)
        if !updated.openAgents.contains(reference) {
            guard updated.openAgents.count < Self.maximumOpenAgents else { throw NavigationError.limitExceeded }
            updated.openAgents.append(reference)
        }
        updated.selectedProjectID = project.id
        updated.selectedAgent = reference
        updated.mode = .workspace
        self = updated
    }

    /// Closes a UI tab only; deliberately has no engine/process dependency.
    public mutating func close(_ reference: DeliveryAgentReference, projects: [Project], agents: [EngineAgent]) {
        openAgents.removeAll { $0 == reference }
        if selectedAgent == reference { selectedAgent = nil }
        reconcile(projects: projects, agents: agents)
    }

    /// Absence removes a tab, never substitutes a new record with the same numeric ID.
    /// Completion/liveness states are intentionally irrelevant to navigation.
    public mutating func reconcile(projects: [Project], agents: [EngineAgent]) {
        if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
            self.selectedProjectID = nil
            selectedAgent = nil
        }
        openAgents.removeAll { reference in
            guard let agent = Self.exactAgent(reference, agents: agents) else { return true }
            return !projects.contains { Self.matches(agent: agent, project: $0) }
        }
        if let selectedAgent, !visibleOpenAgents(projects: projects, agents: agents).contains(where: {
            $0.id == selectedAgent.id && $0.createdAtMs == selectedAgent.createdAtMs
        }) {
            self.selectedAgent = nil
        }
    }

    /// Board/list are overview modes; changing mode retains the user's tabs and selection.
    public mutating func setMode(_ mode: WorkspaceNavigationMode) { self.mode = mode }

    /// Open tabs in their saved order, restricted to the selected project (or all when nil).
    public func visibleOpenAgents(projects: [Project], agents: [EngineAgent]) -> [EngineAgent] {
        let scope = projects.filter { selectedProjectID == nil || $0.id == selectedProjectID }
        return openAgents.compactMap { reference in
            guard let agent = Self.exactAgent(reference, agents: agents),
                  scope.contains(where: { Self.matches(agent: agent, project: $0) }) else { return nil }
            return agent
        }
    }

    /// Use the registered original project, not cwd: worktree agents run in another directory.
    public static func matches(agent: EngineAgent, project: Project) -> Bool {
        guard let agentPath = canonicalPath(agent.project), let projectPath = canonicalPath(project.path) else {
            return false
        }
        return agentPath == projectPath
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func exactAgent(_ reference: DeliveryAgentReference, agents: [EngineAgent]) -> EngineAgent? {
        let matches = agents.filter { $0.id == reference.id && $0.createdAtMs == reference.createdAtMs }
        return matches.count == 1 ? matches.first : nil
    }

    func validate() throws {
        guard openAgents.count <= Self.maximumOpenAgents else { throw NavigationError.limitExceeded }
        guard Set(openAgents).count == openAgents.count,
              selectedAgent.map({ openAgents.contains($0) }) ?? true else { throw NavigationError.invalidState }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(selectedProjectID: values.decodeIfPresent(UUID.self, forKey: .selectedProjectID),
                      openAgents: values.decode([DeliveryAgentReference].self, forKey: .openAgents),
                      selectedAgent: values.decodeIfPresent(DeliveryAgentReference.self, forKey: .selectedAgent),
                      mode: values.decode(WorkspaceNavigationMode.self, forKey: .mode))
    }

    public enum NavigationError: LocalizedError, Equatable {
        case invalidState, limitExceeded, agentUnavailable, projectUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidState: "A seleção de abas contém dados inválidos."
            case .limitExceeded: "O limite de 64 abas abertas foi atingido."
            case .agentUnavailable: "Este registro de agente não está mais disponível. Atualize o workspace."
            case .projectUnavailable: "O projeto deste agente não está cadastrado ou não está mais disponível."
            }
        }
    }
}
