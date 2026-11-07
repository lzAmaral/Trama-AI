import AppKit
import SwiftUI
import TramaCore

struct LiveWorkspaceView: View {
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    @ObservedObject var model: LiveWorkspaceModel
    @State private var search = ""
    @State private var session = ""
    @State private var showsComposer = false
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
    @State private var showsWarnings = false
    @State private var confirmReset = false
    @State private var inboxAgent: EngineAgent?
    @State private var selectedPanel = "terminal"
    @State private var panelRequestID = UUID()
    @State private var inboxPanel = "terminal"
    @State private var composerID = UUID()
    @State private var lastInboxID: UUID?
    @FocusState private var searchFocused: Bool

    private var project: Project? { projects.first { $0.id == selectedProjectID } }
    private var warnings: [String] {
        [model.error, model.connectionError, model.navigationError, model.workflow.error].compactMap { $0 }
    }
    private var projectAgents: [EngineAgent] {
        guard let project else { return model.agents }
        return model.agents.filter { WorkspaceNavigationState.matches(agent: $0, project: project) }
    }
    private var filtered: [EngineAgent] {
        projectAgents.filter { agent in
            (session.isEmpty || agent.session == session) &&
            (showsArchived || inboxOnly || agent.archived != true) &&
            (!inboxOnly || model.workflow.pending.contains { $0.agentRef == agent.deliveryReference }) &&
            (search.isEmpty || [agent.name, agent.task, agent.kind, agent.project].contains { $0.localizedStandardContains(search) })
        }
    }
    private var tabs: [EngineAgent] { model.navigation.visibleOpenAgents(projects: projects, agents: model.agents) }
    private var currentAgent: EngineAgent? {
        guard model.navigation.mode == .workspace else { return nil }
        return projectAgents.first { $0.deliveryReference != nil && $0.deliveryReference == model.navigation.selectedAgent }
    }
    private var canRenameSession: Bool {
        !session.isEmpty && !model.busy && model.agents.filter { $0.session == session }.allSatisfy { $0.state == "exited" }
    }

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            tabStrip
            errorBars
            if let reference = model.pendingReference {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Agente #\(reference.id) iniciado · conectando ao terminal…").lineLimit(1)
                    Spacer()
                    Button("Atualizar") { Task { await model.refresh() } }
                    Button("Voltar ao quadro") { model.showOverview() }
                }.font(TerminalTheme.mono(12)).padding(12)
            }
            if let agent = currentAgent, let reference = agent.deliveryReference {
                LiveAgentDetail(model: model, agentID: agent.id, initial: agent, initialTab: selectedPanel,
                                isEmbedded: true, onClose: { model.close(reference) }, panelRequestID: panelRequestID)
                    .id(reference).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                overview
                ProjectTaskComposer(model: model, project: project, preferredSession: session, onStarted: didStart)
                    .id(composerID).padding(16).disabled(model.pendingReference != nil)
            }
        }
        .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
        .onChange(of: selectedProjectID) { _, id in
            if model.navigation.selectedProjectID != id { model.selectProject(id) }
            search = ""; session = ""; inboxOnly = false
        }
        .onChange(of: model.navigation.selectedProjectID) { _, id in
            if selectedProjectID != id { selectedProjectID = id }
        }
        .onChange(of: model.sessions) { _, names in
            if !session.isEmpty && !names.contains(session) { session = "" }
        }
        .task {
            model.workflow.update { try model.workflow.repository.recordVisit() }
            await model.loadProviders()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.workflow.update { try model.workflow.repository.recordVisit() }
        }
        .background { Button("Buscar agentes") { searchFocused = true }.keyboardShortcut("f").hidden() }
        .sheet(isPresented: $showsComposer) {
            NewAgentView(model: model, projects: projects, initialProjectID: selectedProjectID,
                         initialSession: session, onStarted: didStart)
        }
        .sheet(isPresented: $showsRetention) { LogRetentionView(client: model.client) }
        .sheet(isPresented: $showsInbox, onDismiss: {
            if let agent = inboxAgent { inboxAgent = nil; open(agent, panel: inboxPanel) }
        }) {
            DeliveryInboxView(workflow: model.workflow, agents: model.agents) { agent, panel in
                inboxAgent = agent; inboxPanel = panel
            }
        }
        .sheet(isPresented: $showsPilot) { DeliveryPilotView(workflow: model.workflow) }
        .alert("Nova sessão", isPresented: $showsNewSession) {
            TextField("Nome da sessão", text: $newSession)
            Button("Cancelar", role: .cancel) { }
            Button("Criar") {
                let name = newSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await model.perform { try await model.client.createSession(name: name); session = name } }
            }.disabled(newSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        } message: { Text("Sessões agrupam agentes. O projeto e a pasta de destino continuam explícitos no compositor.") }
        .alert("Renomear sessão", isPresented: $showsRenameSession) {
            TextField("Novo nome", text: $renamedSession)
            Button("Cancelar", role: .cancel) { }
            Button("Renomear") {
                let from = sessionToRename
                let to = renamedSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard canRenameSession, !to.isEmpty else { return }
                Task { await model.perform { try await model.client.renameSession(from: from, to: to); session = to } }
            }.disabled(renamedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedSession == sessionToRename || model.busy)
        } message: { Text("Os agentes encerrados de \(sessionToRename) passarão a usar o novo nome.") }
        .alert("Redefinir preferências de navegação?", isPresented: $confirmReset) {
            Button("Cancelar", role: .cancel) { }
            Button("Redefinir navegação") { model.resetNavigation() }
        } message: { Text("Redefine projeto selecionado, abas e visualização. Não encerra agentes nem apaga projetos, comentários ou arquivos.") }
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project == nil ? "Todos os projetos" : "Projeto ativo")
                        .font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
                    Text(project?.name ?? "Seus agentes").font(.system(size: 28, weight: .semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let project {
                        Text(project.path).font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(project.path)
                    }
                }
                Spacer(minLength: 8)
                Button("Novo agente", systemImage: "plus") { newAgent() }.keyboardShortcut("n").disabled(model.busy)
                Menu {
                    Button("Atualizar agentes") { Task { await model.refresh() } }
                    Button("Nova tarefa com opções…") { showsComposer = true }.disabled(project == nil || model.busy)
                    Divider()
                    Button("Nova sessão…") { newSession = ""; showsNewSession = true }.disabled(model.busy)
                    Button("Renomear sessão…") {
                        sessionToRename = session; renamedSession = session; showsRenameSession = true
                    }.disabled(!canRenameSession)
                    Button("Retenção de logs…") { showsRetention = true }
                    Button("Piloto e alertas…") { showsPilot = true }
                    Divider()
                    Button("Reler navegação salva") { model.reloadNavigation() }
                    Button("Redefinir navegação…") { confirmReset = true }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Opções da área de trabalho")
            }
            HStack(spacing: 12) {
                Text("\(projectAgents.filter(\.isAlive).count) ativos · \(projectAgents.filter { $0.state == "paused" || $0.state == "lost" }.count) precisam de você · \(projectAgents.filter { $0.state == "exited" }.count) encerrados")
                    .foregroundStyle(TerminalTheme.secondary)
                Spacer(minLength: 0)
                Button("Inbox · \(model.workflow.pending.count)") { showsInbox = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button { openNextIntervention() } label: { Image(systemName: "arrow.right.to.line") }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.workflow.pending.isEmpty)
                    .help("Próximo item da inbox (⌘⇧N)").accessibilityLabel("Abrir próximo item da inbox")
            }.font(TerminalTheme.mono(11))
        }.padding(20)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button { model.showOverview() } label: {
                    Label("Agentes do projeto", systemImage: "square.grid.2x2").padding(.horizontal, 12).padding(.vertical, 10)
                        .background(currentAgent == nil ? TerminalTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                ForEach(tabs) { agent in
                    if let reference = agent.deliveryReference {
                        HStack(spacing: 8) {
                            Button { open(agent) } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(liveStateColor(agent.state)).frame(width: 6, height: 6)
                                    Text(agent.name).lineLimit(1)
                                    Text(agent.kind).foregroundStyle(TerminalTheme.secondary)
                                }
                            }.buttonStyle(.plain)
                            Button { model.close(reference) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(.plain).help("Fechar aba sem encerrar \(agent.name)")
                                .accessibilityLabel("Fechar aba de \(agent.name), mantendo o processo")
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                            .background(currentAgent?.deliveryReference == reference ? TerminalTheme.surface : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }.scrollIndicators(.hidden).frame(height: 44).overlay(alignment: .bottom) { TerminalRule() }
    }

    @ViewBuilder private var errorBars: some View {
        if let error = warnings.first {
            HStack(alignment: .top) {
                Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(1).help(error)
                Spacer()
                Button("\(warnings.count) aviso(s)") { showsWarnings = true }
                Button("Atualizar") { Task { await model.refresh() } }.disabled(model.refreshing)
            }.font(TerminalTheme.mono(11)).padding(12)
            .popover(isPresented: $showsWarnings) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Avisos da área de trabalho").font(.headline)
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).textSelection(.enabled)
                            Divider()
                        }
                        Button("Reler preferências") { model.reloadNavigation() }
                        Button("Reler inbox") { model.workflow.reload() }
                        if model.error != nil { Button("Dispensar erro da última ação") { model.error = nil } }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 420, height: 320)
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { overviewFilters }
                .padding(.horizontal, 20).padding(.vertical, 12)
            if !model.hasLoaded {
                ProgressView("Carregando agentes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                emptyState
            } else if model.navigation.mode == .list {
                ScrollView { LazyVStack(spacing: 8) { ForEach(filtered) { agentRow($0) } }.padding(20) }
            } else { board }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var overviewFilters: some View {
        Picker("Sessão", selection: $session) {
            Text("Todas as sessões").tag("")
            ForEach(model.sessions, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().frame(width: 160).accessibilityLabel("Filtrar por sessão")
        TextField("Buscar agentes", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
            .frame(minWidth: 100, maxWidth: 200)
        Menu {
            Toggle("Somente inbox", isOn: $inboxOnly)
            Toggle("Mostrar arquivados", isOn: $showsArchived)
        } label: { Image(systemName: "line.3.horizontal.decrease") }
            .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Filtrar agentes")
        Spacer(minLength: 0)
        Picker("Visualização", selection: Binding(
            get: { model.navigation.mode == .list ? WorkspaceNavigationMode.list : .board },
            set: { model.showOverview($0) }
        )) {
            Text("Quadro").tag(WorkspaceNavigationMode.board)
            Text("Lista").tag(WorkspaceNavigationMode.list)
        }.pickerStyle(.segmented).frame(width: 140)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.connectionError == nil ? "terminal" : "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light)).foregroundStyle(TerminalTheme.secondary)
            Text(model.connectionError != nil ? "Não foi possível atualizar os agentes" :
                 (projectAgents.isEmpty ? "Nenhum agente em \(project?.name ?? "seus projetos")" : "Nenhum agente neste filtro"))
                .font(.system(size: 20, weight: .medium))
            Text(project == nil ? "Selecione um projeto na barra lateral para escolher onde a tarefa será executada." :
                 (projectAgents.isEmpty ? "Escreva uma tarefa abaixo, escolha o provedor e inicie o agente." : "Limpe a busca ou ajuste os filtros para ver seus agentes."))
                .foregroundStyle(TerminalTheme.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            if !search.isEmpty || !session.isEmpty || inboxOnly {
                Button("Limpar busca e filtros") { search = ""; session = ""; inboxOnly = false }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var board: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        stateColumn("Precisa de você", states: ["paused", "lost"], width: geometry.size.width)
                        stateColumn("Trabalhando", states: ["working"], width: geometry.size.width)
                        stateColumn("Pronto para revisar", states: ["done"], width: geometry.size.width)
                        stateColumn("Disponíveis", states: ["idle"], width: geometry.size.width)
                    }
                    let others = filtered.filter { !["paused", "lost", "working", "done", "idle"].contains($0.state) }
                    if !others.isEmpty {
                        DisclosureGroup("Encerrados e outros estados · \(others.count)") {
                            LazyVStack(spacing: 8) { ForEach(others) { agentRow($0) } }.padding(.top, 12)
                        }
                    }
                }.padding(20)
            }
        }
    }

    private func stateColumn(_ title: String, states: [String], width: CGFloat) -> some View {
        let items = filtered.filter { states.contains($0.state) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(liveStateColor(states[0])).frame(width: 6, height: 6)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(items.count)").foregroundStyle(TerminalTheme.secondary)
            }
            if items.isEmpty { Text("Nenhum agente").foregroundStyle(TerminalTheme.secondary).padding(.top, 12) }
            ForEach(items) { card($0) }
        }.frame(width: max(180, (width - 88) / 4), alignment: .topLeading)
    }

    private func card(_ agent: EngineAgent) -> some View {
        Button { open(agent) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(agent.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("#\(agent.id)").foregroundStyle(TerminalTheme.secondary)
                }
                Text("\(URL(fileURLWithPath: agent.project).lastPathComponent) · \(agent.kind)")
                    .foregroundStyle(TerminalTheme.accent).lineLimit(1)
                Text(agent.activity.isEmpty ? agent.task : agent.activity).lineLimit(4).foregroundStyle(TerminalTheme.secondary)
                HStack {
                    Text(agent.archived == true ? "Arquivado" : liveStateTitle(agent.state)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                }.foregroundStyle(liveStateColor(agent.state)).font(TerminalTheme.mono(10))
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(TerminalTheme.border)).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Abrir \(agent.name) na área de trabalho")
            .accessibilityLabel("Abrir \(agent.name), \(agent.kind), \(liveStateTitle(agent.state))")
    }

    private func agentRow(_ agent: EngineAgent) -> some View {
        Button { open(agent) } label: {
            HStack(spacing: 12) {
                Circle().fill(liveStateColor(agent.state)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.system(size: 14, weight: .medium))
                    Text(agent.task).lineLimit(1).foregroundStyle(TerminalTheme.secondary)
                }
                Spacer()
                Text(agent.kind).foregroundStyle(TerminalTheme.accent)
                Text(liveStateTitle(agent.state)).foregroundStyle(TerminalTheme.secondary)
                Image(systemName: "chevron.right")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func newAgent() { model.showOverview(); composerID = UUID() }
    private func didStart(_ reference: DeliveryAgentReference, _ projectID: UUID) {
        selectedPanel = "terminal"; panelRequestID = UUID(); selectedProjectID = projectID
        model.didStart(reference, projectID: projectID)
    }
    private func open(_ agent: EngineAgent, panel: String = "terminal") {
        selectedPanel = panel; panelRequestID = UUID(); model.open(agent); selectedProjectID = model.navigation.selectedProjectID
        if let ref = agent.deliveryReference { model.workflow.opened(ref, panel: panel) }
    }
    private func openNextIntervention() {
        let available = model.workflow.pending.filter { item in model.agents.contains { $0.deliveryReference == item.agentRef } }
            .sorted {
                if ($0.readAt == nil) != ($1.readAt == nil) { return $0.readAt == nil }
                return $0.createdAt < $1.createdAt
            }
        let next = available.first { $0.readAt == nil } ?? {
            guard !available.isEmpty else { return nil as DeliveryIntervention? }
            if let index = available.firstIndex(where: { $0.id == lastInboxID }) { return available[(index + 1) % available.count] }
            return available.first
        }()
        if let next, let agent = model.agents.first(where: { $0.deliveryReference == next.agentRef }) {
            lastInboxID = next.id; open(agent, panel: interventionPanel(next))
        } else { showsInbox = true }
    }
}

func liveStateTitle(_ state: String) -> String {
    switch state {
    case "paused": "Precisa de você"
    case "working": "Trabalhando"
    case "done": "Pronto para revisar"
    case "idle": "Disponível"
    case "lost": "Interrompido"
    case "exited": "Encerrado"
    default: "Desconhecido: \(state)"
    }
}
func liveStateColor(_ state: String) -> Color {
    switch state {
    case "paused", "lost": TerminalTheme.warning
    case "done", "working": TerminalTheme.accent
    default: TerminalTheme.secondary
    }
}
