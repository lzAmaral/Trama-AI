import Combine
import Foundation
import TramaCore

@MainActor
final class LiveWorkspaceModel: ObservableObject {
    let client: OctoEngineClient
    let workflow: DeliveryWorkflowViewModel
    private let navigationRepository: WorkspaceNavigationRepository
    private let sessionRepository: ProjectSessionRepository
    private var workflowUpdates: AnyCancellable?
    private var projects: [Project] = []
    private var hasSuccessfulPoll = false
    private var refreshInFlight = false
    private var canPersistNavigation = true
    private var pendingProjectID: UUID?

    @Published private(set) var navigation = WorkspaceNavigationState()
    @Published var navigationError: String?
    @Published var promptDrafts: [DeliveryAgentReference: String] = [:]
    @Published var projectTaskDrafts: [UUID: String] = [:]
    // Presentation only: changing the page size never stops or suspends an agent.
    @Published var terminalPreviewDensity: TerminalPreviewDensity = .economical
    @Published private(set) var pendingReference: DeliveryAgentReference?
    @Published var agents: [EngineAgent] = []
    @Published var sessions: [String] = []
    @Published private(set) var projectSessions: [ProjectSession] = []
    @Published private(set) var sessionCatalogError: String?
    @Published var providers: [EngineProvider] = []
    @Published var error: String?
    @Published var connectionError: String?
    @Published var busy = false
    @Published var refreshing = false
    @Published var hasLoaded = false
    @Published var loadingProviders = false
    @Published var providerError: String?

    init(client: OctoEngineClient = OctoEngineClient(executableURL: OctoEngineClient.defaultExecutableURL,
                                                    homeURL: OctoEngineClient.defaultHomeURL, timeout: 30),
         navigationRepository: WorkspaceNavigationRepository = WorkspaceNavigationRepository()) {
        self.client = client
        self.navigationRepository = navigationRepository
        sessionRepository = ProjectSessionRepository(fileURL: client.homeURL.appendingPathComponent("trama-project-sessions.json"))
        workflow = DeliveryWorkflowViewModel(engineHome: client.homeURL)
        do { projectSessions = try sessionRepository.load() }
        catch { sessionCatalogError = error.localizedDescription }
        do { navigation = try navigationRepository.load() }
        catch {
            navigationError = "Não foi possível restaurar a navegação. As preferências foram preservadas: \(error.localizedDescription)"
            canPersistNavigation = false
        }
        workflowUpdates = workflow.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func configure(projects: [Project]) {
        self.projects = projects
        if hasSuccessfulPoll { navigation.reconcile(projects: projects, agents: agents) }
    }

    func selectProject(_ id: UUID?) {
        if pendingProjectID != id { pendingReference = nil; pendingProjectID = nil }
        changeNavigation { state in
            if hasSuccessfulPoll {
                try state.selectProject(id, projects: projects, agents: agents)
            } else {
                guard id == nil || projects.contains(where: { $0.id == id }) else {
                    throw WorkspaceNavigationState.NavigationError.projectUnavailable
                }
                state = try WorkspaceNavigationState(selectedProjectID: id,
                    selectedSession: state.selectedProjectID == id ? state.selectedSession : nil, openAgents: state.openAgents,
                    selectedAgent: state.selectedProjectID == id ? state.selectedAgent : nil, mode: state.mode)
            }
        }
    }

    func selectSession(_ name: String?) {
        cancelPendingOpen()
        changeNavigation { state in
            if hasSuccessfulPoll {
                try state.selectSession(name, projects: projects, agents: agents)
            } else {
                // An empty in-memory list is not evidence that restored tabs disappeared.
                state = try WorkspaceNavigationState(selectedProjectID: nil, selectedSession: name,
                    openAgents: state.openAgents,
                    selectedAgent: state.selectedSession == name ? state.selectedAgent : nil,
                    mode: state.mode == .workspace ? .list : state.mode)
            }
        }
    }

    func selectScope(projectID: UUID?, session: String?) {
        cancelPendingOpen()
        changeNavigation { state in
            if hasSuccessfulPoll {
                try state.selectScope(projectID: projectID, session: session, projects: projects, agents: agents)
            } else {
                guard projectID == nil || projects.contains(where: { $0.id == projectID }) else {
                    throw WorkspaceNavigationState.NavigationError.projectUnavailable
                }
                // Until the first successful snapshot, missing agents must not prune restored tabs.
                state = try WorkspaceNavigationState(selectedProjectID: projectID, selectedSession: session,
                    openAgents: state.openAgents, selectedAgent: nil, mode: .list)
            }
        }
    }

    func open(_ agent: EngineAgent) {
        guard let reference = agent.deliveryReference else {
            error = "Este registro não tem identidade de criação. Atualize o motor antes de abri-lo."
            return
        }
        cancelPendingOpen()
        changeNavigation { try $0.open(reference, projects: projects, agents: agents) }
    }

    func close(_ reference: DeliveryAgentReference) {
        changeNavigation { $0.close(reference, projects: projects, agents: agents) }
    }

    func showOverview(_ mode: WorkspaceNavigationMode = .list) {
        cancelPendingOpen()
        changeNavigation { $0.setMode(mode) }
    }

    /// Cancels only automatic navigation after launch, never the launched process.
    func cancelPendingOpen() {
        pendingReference = nil
        pendingProjectID = nil
    }

    func didStart(_ reference: DeliveryAgentReference, projectID: UUID) {
        pendingReference = reference
        pendingProjectID = projectID
        selectProject(projectID)
        focusPendingAgent()
    }

    private func focusPendingAgent() {
        guard let reference = pendingReference,
              let project = projects.first(where: { $0.id == pendingProjectID }),
              let agent = agents.first(where: { $0.deliveryReference == reference }),
              WorkspaceNavigationState.matches(agent: agent, project: project) else { return }
        open(agent)
        if navigation.selectedAgent == reference { pendingReference = nil; pendingProjectID = nil }
    }

    private func changeNavigation(_ operation: (inout WorkspaceNavigationState) throws -> Void) {
        do {
            var next = navigation
            try operation(&next)
            navigation = next
            guard canPersistNavigation else { return }
            _ = try navigationRepository.update { state in
                if hasSuccessfulPoll { state.reconcile(projects: projects, agents: agents) }
                try operation(&state)
            }
            navigationError = nil
        } catch {
            navigationError = "A navegação não foi salva: \(error.localizedDescription)"
        }
    }

    func reloadNavigation() {
        do {
            var restored = try navigationRepository.load()
            if hasSuccessfulPoll { restored.reconcile(projects: projects, agents: agents) }
            navigation = restored
            canPersistNavigation = true
            navigationError = nil
        } catch { navigationError = error.localizedDescription }
    }

    func resetNavigation() {
        do {
            navigation = try navigationRepository.reset()
            canPersistNavigation = true
            navigationError = nil
        } catch { navigationError = error.localizedDescription }
    }

    func sessionName(_ id: String, projectID: UUID?) -> String {
        let projectID = projectID ?? projects.first { ProjectSession.generalID(for: $0.id) == id }?.id
        return ProjectSession.name(for: id, projectID: projectID, catalog: projectSessions)
    }

    var availableProjectSessions: [ProjectSession] {
        projectSessions.filter { $0.managed || !hasSuccessfulPoll || sessions.contains($0.engineID) }
    }

    func projectID(for agent: EngineAgent) -> UUID? {
        projects.first { WorkspaceNavigationState.matches(agent: agent, project: $0) }?.id
    }

    func sessionSelection(projectID: UUID?, preferred: String?) -> EngineSessionSelection {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return EngineSessionSelection(sessions: [], preferredSession: nil)
        }
        let catalog = availableProjectSessions
        let options = ProjectSession.sessions(for: project, agents: agents, catalog: catalog)
        let preferred = preferred.flatMap { options.contains($0) ? $0 : nil }
            ?? ProjectSession.initialID(for: project.id, catalog: catalog)
        return EngineSessionSelection(sessions: options, preferredSession: preferred)
    }

    func createProjectSession(name: String, projectID: UUID?) throws {
        guard let projectID, projects.contains(where: { $0.id == projectID }) else {
            throw WorkspaceNavigationState.NavigationError.projectUnavailable
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try saveSessionName(name, id: id, projectID: projectID, managed: true)
        selectScope(projectID: projectID, session: id)
    }

    func renameProjectSession(_ id: String, name: String, projectID: UUID) throws {
        guard sessionSelection(projectID: projectID, preferred: id).options.contains(id) else {
            throw WorkspaceNavigationState.NavigationError.invalidState
        }
        try saveSessionName(name, id: id, projectID: projectID)
    }

    private func saveSessionName(_ name: String, id: String, projectID: UUID, managed: Bool = false) throws {
        let latest = try sessionRepository.load()
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw WorkspaceNavigationState.NavigationError.projectUnavailable
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ProjectSession.sessions(for: project, agents: agents, catalog: latest).contains(where: {
            let implicitEmptyGeneral = $0 == ProjectSession.generalID(for: projectID)
                && !latest.contains(where: { $0.projectID == projectID && $0.engineID == ProjectSession.generalID(for: projectID) })
                && !agents.contains(where: { $0.session == ProjectSession.generalID(for: projectID) })
            return $0 != id && !implicitEmptyGeneral && ProjectSession.name(for: $0, projectID: projectID, catalog: latest) == name
        }) else { throw ProjectSessionRepository.RepositoryError.duplicateName }
        let managed = latest.first { $0.projectID == projectID && $0.engineID == id }?.managed
            ?? (managed || id == ProjectSession.generalID(for: projectID))
        projectSessions = try sessionRepository.save(ProjectSession(projectID: projectID, engineID: id, name: name, managed: managed))
        sessionCatalogError = nil
    }

    /// Called only for an explicit start/move. Merely browsing a project never creates a holder or engine session.
    func prepareSession(_ id: String, projectID: UUID) async throws {
        let latest = try sessionRepository.load()
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw WorkspaceNavigationState.NavigationError.invalidState
        }
        let current = try await client.listSessions()
        let available = latest.filter { $0.managed || current.sessions.contains($0.engineID) }
        guard ProjectSession.sessions(for: project, agents: current.agents, catalog: available).contains(id) else {
            throw WorkspaceNavigationState.NavigationError.invalidState
        }
        if current.sessions.contains(id) { return }
        guard id == ProjectSession.generalID(for: projectID) || latest.contains(where: {
            $0.projectID == projectID && $0.engineID == id && $0.managed
        }) else { throw WorkspaceNavigationState.NavigationError.invalidState }
        do { try await client.createSession(name: id) }
        catch {
            // Another instance may have created the same grouping. Never retry a start operation.
            guard let observed = try? await client.listSessions(), observed.sessions.contains(id) else { throw error }
        }
    }

    func refresh(showProgress: Bool = true) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        if showProgress || !hasLoaded { refreshing = true }
        defer {
            refreshInFlight = false
            if refreshing { refreshing = false }
            if !hasLoaded { hasLoaded = true }
        }
        do {
            let result = try await client.listSessions()
            try Task.checkCancellation()
            if agents != result.agents { agents = result.agents }
            if sessions != result.sessions { sessions = result.sessions }
            do {
                let latest = try sessionRepository.load()
                if projectSessions != latest { projectSessions = latest }
                if sessionCatalogError != nil { sessionCatalogError = nil }
            } catch {
                if sessionCatalogError != error.localizedDescription { sessionCatalogError = error.localizedDescription }
            }
            hasSuccessfulPoll = true
            var nextNavigation = navigation
            let available: [String]? = nextNavigation.selectedProjectID != nil && sessionCatalogError != nil ? nil : nextNavigation.selectedProjectID.map {
                sessionSelection(projectID: $0, preferred: nil).options
            } ?? sessions
            nextNavigation.reconcile(projects: projects, agents: agents, sessions: available)
            if navigation != nextNavigation { navigation = nextNavigation }
            focusPendingAgent()
            await workflow.observe(result.agents)
            if connectionError != nil { connectionError = nil }
        } catch is CancellationError { } catch {
            let message = error.localizedDescription
            if connectionError != message { connectionError = message }
        }
    }

    func loadProviders() async {
        guard !loadingProviders else { return }
        loadingProviders = true
        defer { loadingProviders = false }
        do {
            let result = try await client.inspect()
            try Task.checkCancellation()
            providers = result.providers.filter(\.installed)
            providerError = nil
        } catch is CancellationError { } catch { providerError = error.localizedDescription }
    }

    func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await operation()
            await refresh()
        } catch is CancellationError {
            error = "Operação interrompida. Atualize antes de tentar novamente; a ação pode ter ocorrido."
        } catch { self.error = error.localizedDescription }
    }
}
