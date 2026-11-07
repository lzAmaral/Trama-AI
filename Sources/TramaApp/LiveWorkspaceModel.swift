import Combine
import Foundation
import TramaCore

@MainActor
final class LiveWorkspaceModel: ObservableObject {
    let client: OctoEngineClient
    let workflow: DeliveryWorkflowViewModel
    private let navigationRepository: WorkspaceNavigationRepository
    private var workflowUpdates: AnyCancellable?
    private var projects: [Project] = []
    private var hasSuccessfulPoll = false
    private var canPersistNavigation = true
    private var pendingProjectID: UUID?

    @Published private(set) var navigation = WorkspaceNavigationState()
    @Published var navigationError: String?
    @Published var promptDrafts: [DeliveryAgentReference: String] = [:]
    @Published var projectTaskDrafts: [UUID: String] = [:]
    @Published private(set) var pendingReference: DeliveryAgentReference?
    @Published var agents: [EngineAgent] = []
    @Published var sessions: [String] = []
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
        workflow = DeliveryWorkflowViewModel(engineHome: client.homeURL)
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
                state = try WorkspaceNavigationState(selectedProjectID: id, openAgents: state.openAgents,
                    selectedAgent: state.selectedProjectID == id ? state.selectedAgent : nil, mode: state.mode)
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

    func showOverview(_ mode: WorkspaceNavigationMode = .board) {
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

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; hasLoaded = true }
        do {
            let result = try await client.listSessions()
            try Task.checkCancellation()
            agents = result.agents
            sessions = result.sessions
            hasSuccessfulPoll = true
            navigation.reconcile(projects: projects, agents: agents)
            focusPendingAgent()
            workflow.observe(result.agents)
            connectionError = nil
        } catch is CancellationError { } catch { connectionError = error.localizedDescription }
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
