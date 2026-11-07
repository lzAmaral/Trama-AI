import Foundation
import AppKit
import Combine
import SwiftUI
import TramaCore

@MainActor
final class LiveWorkspaceModel: ObservableObject {
    let client = OctoEngineClient(executableURL: OctoEngineClient.defaultExecutableURL,
                                 homeURL: OctoEngineClient.defaultHomeURL, timeout: 30)
    let workflow = DeliveryWorkflowViewModel(engineHome: OctoEngineClient.defaultHomeURL)
    private var workflowUpdates: AnyCancellable?
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

    init() {
        workflowUpdates = workflow.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
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
            workflow.observe(result.agents)
            connectionError = nil
        } catch is CancellationError { } catch {
            self.connectionError = error.localizedDescription
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
            error = "Operação interrompida. Atualize o quadro antes de tentar novamente; a ação pode ter ocorrido."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LiveWorkspaceView: View {
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    @StateObject private var model = LiveWorkspaceModel()
    @State private var search = ""
    @State private var session = ""
    @State private var listMode = false
    @State private var showsComposer = false
    @State private var selectedAgent: EngineAgent?
    @State private var showsNewSession = false
    @State private var newSession = ""
    @State private var showsRenameSession = false
    @State private var renamedSession = ""
    @State private var sessionToRename = ""
    @State private var showsRetention = false
    @State private var showsArchived = false
    @State private var inboxOnly = false
    @State private var showsInbox = false
    @State private var showsPilot = false
    @State private var inboxAgent: EngineAgent?
    @State private var selectedPanel = "terminal"
    @State private var inboxPanel = "terminal"
    @State private var lastInboxID: UUID?
    @FocusState private var searchFocused: Bool
    private let states = ["paused", "working", "done", "idle", "lost", "exited"]

    private var canRenameSession: Bool {
        !session.isEmpty && !model.busy && model.agents.filter { $0.session == session }.allSatisfy { $0.state == "exited" }
    }

    private var filtered: [EngineAgent] {
        let path = projects.first { $0.id == selectedProjectID }?.path
        return model.agents.filter { agent in
            (path == nil || URL(fileURLWithPath: agent.project).standardizedFileURL.resolvingSymlinksInPath().path == path) &&
            (session.isEmpty || agent.session == session) &&
            (showsArchived || inboxOnly || agent.archived != true) &&
            (!inboxOnly || model.workflow.pending.contains { $0.agentRef == agent.deliveryReference }) &&
            (search.isEmpty || [agent.name, agent.task, agent.kind, agent.project].contains { $0.localizedStandardContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            DeliveryInboxBar(workflow: model.workflow, onlyPending: $inboxOnly,
                             showsInbox: $showsInbox, showsPilot: $showsPilot,
                             next: openNextIntervention)
                .padding(.horizontal, 20).padding(.bottom, 12)
            TerminalRule()
            if let error = model.error ?? model.connectionError {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled)
                    Spacer()
                    if model.error != nil { Button("Dispensar") { model.error = nil } }
                    Button("Atualizar") { Task { await model.refresh() } }.disabled(model.refreshing)
                }.padding(16)
            }
            agentContent
            TerminalRule()
            Text(model.connectionError != nil && !model.agents.isEmpty
                 ? "Sessões reais · dados da última atualização; conexão indisponível"
                 : "Sessões reais · fechar a janela não encerra os processos")
                .foregroundStyle(TerminalTheme.secondary).padding(12)
        }
        .font(TerminalTheme.mono(12))
        .foregroundStyle(TerminalTheme.primary)
        .background(TerminalTheme.background)
        .task {
            model.workflow.update { try model.workflow.repository.recordVisit() }
            await model.loadProviders()
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: model.sessions) { _, names in
            if !session.isEmpty && !names.contains(session) { session = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.workflow.update { try model.workflow.repository.recordVisit() }
        }
        .background {
            Button("Buscar agentes") { searchFocused = true }
                .keyboardShortcut("f").hidden()
        }
        .sheet(isPresented: $showsComposer) {
            NewAgentView(model: model, projects: projects, initialProjectID: selectedProjectID, initialSession: session)
        }
        .sheet(isPresented: $showsRetention) { LogRetentionView(client: model.client) }
        .sheet(isPresented: $showsInbox, onDismiss: {
            if let agent = inboxAgent { inboxAgent = nil; selectedPanel = inboxPanel; selectedAgent = agent }
        }) {
            DeliveryInboxView(workflow: model.workflow, agents: model.agents) { agent, panel in inboxAgent = agent; inboxPanel = panel }
        }
        .sheet(isPresented: $showsPilot) { DeliveryPilotView(workflow: model.workflow) }
        .sheet(item: $selectedAgent) { agent in
            LiveAgentDetail(model: model, agentID: agent.id, initial: agent, initialTab: selectedPanel)
        }
        .alert("Nova sessão", isPresented: $showsNewSession) {
            TextField("Nome da sessão", text: $newSession)
            Button("Cancelar", role: .cancel) { }
            Button("Criar") {
                let name = newSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await model.perform { try await model.client.createSession(name: name) } }
            }.disabled(newSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        } message: { Text("Agrupe tarefas e agentes em uma sessão do motor.") }
        .alert("Renomear sessão", isPresented: $showsRenameSession) {
            TextField("Novo nome", text: $renamedSession)
            Button("Cancelar", role: .cancel) { }
            Button("Renomear") {
                let from = sessionToRename
                guard model.agents.filter({ $0.session == from }).allSatisfy({ $0.state == "exited" }) else { return }
                let to = renamedSession.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await model.perform {
                        try await model.client.renameSession(from: from, to: to)
                        session = to
                    }
                }
            }.disabled(renamedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedSession == sessionToRename || model.busy)
        } message: { Text("Os agentes de \(sessionToRename) passarão a usar o novo nome.") }
    }

    @ViewBuilder private var agentContent: some View {
        if !model.hasLoaded {
            ProgressView("Carregando sessões locais…")
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if filtered.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.connectionError != nil ? "[erro] Sessões indisponíveis" : (model.agents.isEmpty ? "[info] Nenhum agente registrado" : "[info] Nenhum resultado neste filtro"))
                    .foregroundStyle(model.connectionError != nil ? TerminalTheme.warning : TerminalTheme.accent)
                    .accessibilityAddTraits(.isHeader)
                Text(model.connectionError != nil
                     ? "Atualize o quadro para tentar conectar ao motor local novamente."
                     : (projects.isEmpty ? "Adicione uma pasta na barra lateral para iniciar uma tarefa."
                        : (model.agents.isEmpty ? "Inicie uma tarefa para acompanhar agentes reais neste quadro." : "Experimente outro termo, sessão ou projeto.")))
                    .foregroundStyle(TerminalTheme.secondary)
                if !search.isEmpty || !session.isEmpty || selectedProjectID != nil || inboxOnly {
                    Button("Limpar filtros") { search = ""; session = ""; selectedProjectID = nil; inboxOnly = false }
                }
                Spacer()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        } else if listMode {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filtered) { agent in card(agent) }
                }.padding(20)
            }
        } else {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(states, id: \.self) { state in
                            let items = filtered.filter { $0.state == state }
                            if !items.isEmpty || !["lost", "exited"].contains(state) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(liveStateTitle(state)).foregroundStyle(liveStateColor(state))
                                        Spacer()
                                        Text("\(items.count)").foregroundStyle(TerminalTheme.secondary)
                                    }
                                    if items.isEmpty { Text("Sem agentes").foregroundStyle(TerminalTheme.secondary) }
                                    ForEach(items) { agent in card(agent) }
                                }.frame(width: max(240, (geometry.size.width - 88) / 4))
                            }
                        }
                        let unknown = filtered.filter { !states.contains($0.state) }
                        if !unknown.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Estado desconhecido")
                                ForEach(unknown) { agent in card(agent) }
                            }.frame(width: 240)
                        }
                    }.padding(20)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("trama > sessões").font(TerminalTheme.mono(24, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.busy { ProgressView("Aplicando…").controlSize(.small) }
                Button("Nova tarefa", systemImage: "plus") { showsComposer = true }
                    .disabled(projects.isEmpty || model.busy)
                    .keyboardShortcut("n")
                    .help("Iniciar uma sessão real em um projeto cadastrado (⌘N)")
            }
            Text("\(filtered.count) agentes neste filtro")
                .foregroundStyle(TerminalTheme.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { filters; searchField }
                VStack { filters; searchField }
            }
            HStack {
                Toggle("Mostrar arquivados", isOn: $showsArchived).toggleStyle(.checkbox)
                Spacer()
                Button("Retenção de logs…") { showsRetention = true }
                    .help("Revisar arquivos de log antes de excluir manualmente")
            }
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack { sessionPicker; sessionActions; displayPicker }
            VStack(alignment: .leading, spacing: 8) {
                HStack { sessionPicker; displayPicker }
                sessionActions
            }
        }
    }

    private var sessionPicker: some View {
        Picker("Sessão", selection: $session) {
            Text("Todas as sessões").tag("")
            ForEach(model.sessions, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 180).accessibilityLabel("Filtrar por sessão")
    }

    private var sessionActions: some View {
        HStack {
            Button("Renomear…") {
                sessionToRename = session; renamedSession = session; showsRenameSession = true
            }.disabled(!canRenameSession)
                .help("Selecione uma sessão e encerre seus agentes antes de renomear")
                .accessibilityLabel("Renomear sessão selecionada")
            Button("Nova sessão…") { newSession = ""; showsNewSession = true }.disabled(model.busy)
        }
    }

    private var displayPicker: some View {
        Picker("Visualização", selection: $listMode) {
            Text("Quadro").tag(false)
            Text("Lista").tag(true)
        }.pickerStyle(.segmented).frame(width: 140)
    }

    private var searchField: some View {
        TextField("Buscar tarefa, projeto ou provedor", text: $search)
            .textFieldStyle(.roundedBorder).frame(minWidth: 160)
            .focused($searchFocused).accessibilityLabel("Buscar tarefa, projeto ou provedor")
    }

    private func card(_ agent: EngineAgent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(agent.name).font(TerminalTheme.mono(13, weight: .semibold))
                Spacer()
                Text("#\(agent.id)").foregroundStyle(TerminalTheme.secondary)
            }
            Text("\(agent.kind) · \(agent.session)").foregroundStyle(TerminalTheme.accent)
            Text(URL(fileURLWithPath: agent.project).lastPathComponent).foregroundStyle(TerminalTheme.secondary)
            if let branch = agent.branch { Text(branch).foregroundStyle(TerminalTheme.secondary) }
            Text(agent.archived == true ? "Arquivado · \(liveStateTitle(agent.state))" : liveStateTitle(agent.state))
                .foregroundStyle(liveStateColor(agent.state))
            if let parent = agent.parentId { Text("Agente pai: #\(parent)").foregroundStyle(TerminalTheme.secondary) }
            Text(agent.activity.isEmpty ? agent.task : agent.activity).lineLimit(5)
                .foregroundStyle(TerminalTheme.secondary)
            Button("Abrir agente") { open(agent) }
                .accessibilityLabel("Abrir \(agent.name), agente \(agent.id), \(liveStateTitle(agent.state))")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(agent.state == "paused" ? TerminalTheme.warning : TerminalTheme.border))
    }

    private func open(_ agent: EngineAgent, panel: String = "terminal") {
        if let ref = agent.deliveryReference { model.workflow.opened(ref, panel: panel) }
        selectedPanel = panel
        selectedAgent = agent
    }

    private func openNextIntervention() {
        let candidates = model.workflow.pending.sorted {
            if ($0.readAt == nil) != ($1.readAt == nil) { return $0.readAt == nil }
            return $0.createdAt < $1.createdAt
        }
        let available = candidates.filter { item in model.agents.contains { $0.deliveryReference == item.agentRef } }
        let next = available.first { $0.readAt == nil } ?? {
            guard !available.isEmpty else { return nil as DeliveryIntervention? }
            if let index = available.firstIndex(where: { $0.id == lastInboxID }) { return available[(index + 1) % available.count] }
            return available.first
        }()
        if let next, let agent = model.agents.first(where: { $0.deliveryReference == next.agentRef }) {
            lastInboxID = next.id
            open(agent, panel: interventionPanel(next))
        } else { showsInbox = true }
    }
}

private struct DeliveryInboxBar: View {
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    @Binding var onlyPending: Bool
    @Binding var showsInbox: Bool
    @Binding var showsPilot: Bool
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            if let error = workflow.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled)
                    Button("Reler dados locais") { workflow.reload() }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        Button(workflow.snapshot == nil ? "Inbox indisponível" : "Inbox · \(workflow.pending.count) pendentes · \(workflow.unreadCount) não vistos") { showsInbox = true }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        Toggle("Só inbox", isOn: $onlyPending).toggleStyle(.checkbox).disabled(workflow.snapshot == nil)
        Button("Próximo item") { next() }.keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(workflow.pending.isEmpty)
            .help("Abrir próximo item da inbox (⌘⇧N). Não envia resposta ao CLI.")
        Button("Piloto e alertas…") { showsPilot = true }
    }
}

func liveStateTitle(_ state: String) -> String {
    switch state {
    case "paused": "Precisa de você"
    case "working": "Em andamento"
    case "done": "Concluído"
    case "idle": "Disponível"
    case "lost": "Interrompido"
    case "exited": "Encerrado"
    default: "Desconhecido: \(state)"
    }
}

func liveStateColor(_ state: String) -> Color {
    switch state {
    case "paused", "lost": TerminalTheme.warning
    case "done": TerminalTheme.accent
    default: TerminalTheme.secondary
    }
}
