import AppKit
import SwiftUI
import TramaCore

struct LiveWorkspaceView: View {
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    @ObservedObject var model: LiveWorkspaceModel
    var usageSnapshots: [String: EngineUsage] = [:]
    var onConsultUsage: (EngineProvider) -> Void = { _ in }
    var onInspectEngine: () -> Void = {}
    @State private var search = ""
    let onAddProject: () -> Void
    @State private var taskProjectID: UUID?
    @State private var showsSearch = false

    private var session: String { model.navigation.selectedSession ?? "" }
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
    private var sessionAgents: [EngineAgent] {
        model.agents.filter { session.isEmpty || $0.session == session }
    }
    private var projectAgents: [EngineAgent] {
        guard let project else { return sessionAgents }
        return sessionAgents.filter { WorkspaceNavigationState.matches(agent: $0, project: project) }
    }
    private var filtered: [EngineAgent] {
        projectAgents.filter { agent in
            (session.isEmpty || agent.session == session) &&
            (showsArchived || inboxOnly || agent.archived != true) &&
            (!inboxOnly || model.workflow.pending.contains { $0.agentRef == agent.deliveryReference }) &&
            (search.isEmpty || [agent.name, agent.task, agent.kind, agent.project].contains { $0.localizedStandardContains(search) })
        }
    }
    private var tabs: [EngineAgent] {
        model.navigation.openAgents.compactMap { reference in
            model.agents.first { $0.deliveryReference == reference }
        }
    }
    private var currentAgent: EngineAgent? {
        guard model.navigation.mode == .workspace else { return nil }
        return projectAgents.first { $0.deliveryReference != nil && $0.deliveryReference == model.navigation.selectedAgent }
    }
    private var canRenameSession: Bool {
        !session.isEmpty && !model.busy && model.agents.filter { $0.session == session }.allSatisfy { $0.state == "exited" }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                projectHeader
                WorkspaceOverviewHeader(metrics: overviewMetrics) {
                    WorkspaceUsageSummary(snapshots: usageSnapshots, providers: model.providers,
                                          onConsult: onConsultUsage, onInspect: onInspectEngine)
                }
                overview
                ProjectTaskComposer(model: model, projects: projects, selectedProjectID: $taskProjectID,
                                    preferredSession: session, onAddProject: onAddProject, onStarted: didStart)
                    .id(composerID).padding(.horizontal, 24).padding(.bottom, 8).padding(.top, 8)
                    .disabled(model.pendingReference != nil)
            }
        }
        .font(TerminalTheme.ui(13)).foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
        .onChange(of: selectedProjectID) { _, id in
            if model.navigation.selectedProjectID != id { model.selectProject(id) }
            search = ""; inboxOnly = false
        }
        .onChange(of: model.navigation.selectedProjectID) { _, id in
            if selectedProjectID != id { selectedProjectID = id }
        }
        .onChange(of: model.navigation.selectedSession) { _, _ in search = ""; inboxOnly = false }
        .onAppear { taskProjectID = selectedProjectID }
        .task {
            await model.workflow.update { try $0.recordVisit() }
            await model.loadProviders()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.workflow.update { try $0.recordVisit() } }
        }
        .background { Button("Buscar agentes") { showsSearch = true }.keyboardShortcut("f").hidden() }
        .sheet(isPresented: $showsComposer) {
            NewAgentView(model: model, projects: projects, initialProjectID: taskProjectID,
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
                let projectID = selectedProjectID
                Task { await model.perform { try await model.client.createSession(name: name); model.selectScope(projectID: projectID, session: name) } }
            }.disabled(newSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        } message: { Text("Sessões agrupam agentes. O projeto e a pasta de destino continuam explícitos no compositor.") }
        .alert("Renomear sessão", isPresented: $showsRenameSession) {
            TextField("Novo nome", text: $renamedSession)
            Button("Cancelar", role: .cancel) { }
            Button("Renomear") {
                let from = sessionToRename
                let to = renamedSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard canRenameSession, !to.isEmpty else { return }
                let projectID = selectedProjectID
                Task { await model.perform { try await model.client.renameSession(from: from, to: to); model.selectScope(projectID: projectID, session: to) } }
            }.disabled(renamedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedSession == sessionToRename || model.busy)
        } message: { Text("A sessão \(sessionToRename) é compartilhada. O novo nome será aplicado aos agentes de todos os projetos que usam essa sessão.") }
        .alert("Redefinir preferências de navegação?", isPresented: $confirmReset) {
            Button("Cancelar", role: .cancel) { }
            Button("Redefinir navegação") { model.resetNavigation() }
        } message: { Text("Redefine projeto selecionado, abas e visualização. Não encerra agentes nem apaga projetos, comentários ou arquivos.") }
    }

    private var projectHeader: some View {
        HStack(spacing: 16) {
            headline.frame(maxWidth: .infinity, alignment: .leading)
            headActions.fixedSize()
        }.padding(.horizontal, 24).padding(.vertical, 8)
    }

    private var overviewMetrics: [OverviewMetric] {
        var metrics = [
            OverviewMetric(title: "agentes", count: filtered.count, color: TerminalTheme.primary),
            OverviewMetric(title: "trabalhando", count: filtered.filter { $0.state == "working" }.count, color: TerminalTheme.accent),
            OverviewMetric(title: "aguardando", count: filtered.filter { $0.state == "paused" }.count, color: TerminalTheme.warning),
            OverviewMetric(title: "para revisar", count: filtered.filter { $0.state == "done" }.count, color: TerminalTheme.positive)
        ]
        let other = filtered.filter { !["working", "paused", "done"].contains($0.state) }.count
        if other > 0 { metrics.append(OverviewMetric(title: "outros estados", count: other, color: TerminalTheme.secondary)) }
        return metrics
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project?.name ?? (session.isEmpty ? "Todos os projetos" : session))
                .font(TerminalTheme.mono(16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .help(project?.name ?? (session.isEmpty ? "Todos os projetos" : session))
                .accessibilityAddTraits(.isHeader)
            if project != nil, !session.isEmpty {
                Text(session).font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary).lineLimit(1).help(session)
            }
        }.frame(minWidth: 120, alignment: .leading)
    }

    private var headActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                displayModes
                searchButton
                workspaceOptions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    displayModes
                    Spacer(minLength: 0)
                    searchButton
                    workspaceOptions
                }
            }
        }.font(TerminalTheme.ui(12))
    }

    private var displayModes: some View {
        HStack(spacing: 2) {
            displayMode("Quadro", mode: .board)
            displayMode("Lista", mode: .list)
            displayMode("Grade", mode: .grid)
        }.padding(3).background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .fixedSize()
    }

    private var searchButton: some View {
        Button { showsSearch.toggle() } label: {
            Image(systemName: "magnifyingglass").frame(width: 28, height: 30)
        }.buttonStyle(.plain).foregroundStyle(search.isEmpty ? TerminalTheme.secondary : TerminalTheme.accent)
            .accessibilityLabel("Buscar agentes").help("Buscar agentes (⌘F)")
            .popover(isPresented: $showsSearch) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Buscar agentes").font(.headline)
                    TextField("Nome, tarefa, projeto ou provedor", text: $search)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .accessibilityLabel("Buscar agentes")
                    HStack {
                        Toggle("Somente inbox", isOn: $inboxOnly)
                        Toggle("Arquivados", isOn: $showsArchived)
                    }
                    if !search.isEmpty || inboxOnly {
                        Button("Limpar filtros") { search = ""; inboxOnly = false }
                    }
                }.font(TerminalTheme.ui(12)).padding(20).frame(width: 340)
                    .onAppear { searchFocused = true }
            }
    }

    private func displayMode(_ title: String, mode: WorkspaceNavigationMode) -> some View {
        let selected = model.navigation.mode == mode || model.navigation.mode == .workspace && mode == .list
        return Button { model.showOverview(mode) } label: {
            Text(title).font(TerminalTheme.ui(12, weight: .semibold))
                .foregroundStyle(selected ? TerminalTheme.primary : TerminalTheme.secondary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(selected ? TerminalTheme.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("Visualização em \(title.lowercased())")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var workspaceOptions: some View {
        Menu {
            Button("Nova tarefa") { newAgent() }.keyboardShortcut("n")
            Button("Atualizar agentes") { Task { await model.refresh() } }
            Button("Nova tarefa com opções…") { showsComposer = true }.disabled(model.busy)
            Divider()
            Button("Inbox · \(model.workflow.pending.count)") { showsInbox = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Próxima intervenção") { openNextIntervention() }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.workflow.pending.isEmpty)
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
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(TerminalTheme.secondary)
        .fixedSize().accessibilityLabel("Opções da área de trabalho")
    }

    private var tabStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    Button { model.showOverview() } label: {
                        Label("Visão geral", systemImage: "rectangle.split.3x1")
                            .font(TerminalTheme.ui(12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(currentAgent == nil ? TerminalTheme.raised : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    ForEach(tabs) { agent in
                        if let reference = agent.deliveryReference {
                            HStack(spacing: 8) {
                                Button { open(agent) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: liveStateSymbol(agent.state)).foregroundStyle(liveStateColor(agent.state))
                                        Text(agent.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                                        Text("#\(agent.id)").foregroundStyle(TerminalTheme.muted)
                                    }
                                }.buttonStyle(.plain).help("\(agent.name)\n\(agent.task)")
                                Button { model.close(reference) } label: {
                                    Image(systemName: "xmark").font(TerminalTheme.ui(9)).frame(width: 16, height: 20)
                                }.buttonStyle(.plain).foregroundStyle(TerminalTheme.muted)
                                    .help("Fechar aba sem encerrar \(agent.name)")
                                    .accessibilityLabel("Fechar aba de \(agent.name), mantendo o processo")
                            }.font(TerminalTheme.mono(11)).padding(.horizontal, 12).frame(height: 30)
                                .background(currentAgent?.deliveryReference == reference ? TerminalTheme.raised : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
            if currentAgent != nil { workspaceOptions.padding(.trailing, 16) }
        }.frame(height: 40).overlay(alignment: .bottom) { TerminalRule() }
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
                        Button("Reler inbox") { Task { await model.workflow.reload() } }
                        if model.error != nil { Button("Dispensar erro da última ação") { model.error = nil } }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 420, height: 320)
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            if !search.isEmpty || inboxOnly || showsArchived {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(search.isEmpty ? "Filtros ativos" : "Busca: \(search)").lineLimit(1)
                    Spacer()
                    Button("Limpar") { search = ""; inboxOnly = false; showsArchived = false }
                }.font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if !model.hasLoaded {
                ProgressView("Carregando agentes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                emptyState
            } else if model.navigation.mode == .list {
                agentList
            } else if model.navigation.mode == .grid {
                WorkspaceTerminalGrid(agents: filtered, client: model.client,
                                      density: $model.terminalPreviewDensity, onOpen: { open($0) })
                    .padding(.horizontal, 24)
            } else { board }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: model.connectionError == nil ? "terminal" : "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(TerminalTheme.muted)
                Text(model.connectionError != nil ? "Não foi possível atualizar os agentes" :
                     (projectAgents.isEmpty ? "Nenhum agente nesta sessão" : "Nenhum agente neste filtro"))
                    .font(TerminalTheme.ui(20, weight: .medium))
                Text(model.connectionError != nil ? "Confira o aviso acima e tente atualizar novamente." :
                     (project == nil ? "Escolha a pasta de destino no compositor e escreva a primeira tarefa." :
                     (projectAgents.isEmpty ? "Descreva a tarefa abaixo. Acompanhe a execução e revise o resultado aqui." : "Limpe a busca ou ajuste os filtros para ver seus agentes.")))
                    .font(TerminalTheme.ui(13)).foregroundStyle(TerminalTheme.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360).fixedSize(horizontal: false, vertical: true)
                if !search.isEmpty || inboxOnly {
                    Button("Limpar busca e filtros") { search = ""; inboxOnly = false }
                }
            }.padding(24).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var board: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    stateColumn("Precisa de você", bucket: 0, width: geometry.size.width)
                    stateColumn("Trabalhando", bucket: 1, width: geometry.size.width)
                    stateColumn("Concluídos", bucket: 2, width: geometry.size.width)
                    stateColumn("Em espera", bucket: 3, width: geometry.size.width)
                }.padding(.horizontal, 24)
                    .frame(height: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func stateColumn(_ title: String, bucket: Int, width: CGFloat) -> some View {
        let items = filtered.filter { workspaceBucket($0.state) == bucket }
        let states = ["paused", "working", "done", "idle"]
        let empty = ["Nenhum agente aguardando", "Nenhum agente trabalhando", "Os resultados aparecem aqui", "Nenhum agente em espera"]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: liveStateSymbol(states[bucket])).foregroundStyle(liveStateColor(states[bucket]))
                    .font(TerminalTheme.ui(12))
                Text(title).font(TerminalTheme.ui(12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(items.count)").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
            }.frame(height: 24).padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        Text(empty[bucket]).font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.muted)
                            .padding(.vertical, 14).padding(.horizontal, 4)
                    }
                    ForEach(items) { card($0) }
                }.padding(.bottom, 4)
            }.frame(maxHeight: .infinity)
        }.frame(width: max(240, (width - 112) / 4), alignment: .topLeading)
    }

    private func card(_ agent: EngineAgent) -> some View {
        Button { open(agent) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: liveStateSymbol(agent.state)).foregroundStyle(liveStateColor(agent.state))
                        .frame(width: 14).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.name).font(TerminalTheme.mono(13, weight: .semibold))
                            .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(TerminalTheme.primary)
                        HStack(spacing: 8) {
                            Text("#\(agent.id)")
                            Spacer(minLength: 0)
                            Text(workspaceLifetime(agent)).help("Tempo desde a criação do registro")
                        }.font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(TerminalTheme.projectColor(agent.project)).frame(width: 6, height: 6)
                        Text(URL(fileURLWithPath: agent.project).lastPathComponent).lineLimit(2)
                            .truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(TerminalTheme.secondary).help(agent.project)
                        Text("·").foregroundStyle(TerminalTheme.muted)
                        Text(agent.kind).foregroundStyle(TerminalTheme.providerColor(agent.kind)).fixedSize()
                    }.font(TerminalTheme.mono(10))
                    if agent.state == "paused" {
                        Text("Aguardando sua resposta").font(TerminalTheme.ui(13, weight: .semibold))
                            .foregroundStyle(TerminalTheme.warning)
                    }
                    Text(agent.activity.isEmpty ? agent.task : agent.activity)
                        .font(agent.kind == "terminal" ? TerminalTheme.mono(12) : TerminalTheme.ui(13))
                        .foregroundStyle(TerminalTheme.secondary).lineLimit(3).multilineTextAlignment(.leading)
                    if let nested = agent.nested {
                        Text("↳ \(nested.kind) · processo local").font(TerminalTheme.mono(10))
                            .foregroundStyle(TerminalTheme.muted).lineLimit(1)
                    }
                    if agent.state == "paused" || agent.state == "lost" {
                        HStack {
                            Text(agent.state == "lost" ? "Abrir sessão interrompida" : "Abrir agente")
                                .font(TerminalTheme.ui(11, weight: .semibold))
                                .foregroundStyle(agent.state == "lost" ? TerminalTheme.danger : TerminalTheme.rgb(0x1a1608))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(agent.state == "paused" ? TerminalTheme.warning : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(TerminalTheme.ui(10))
                        }
                    }
                    if let branch = agent.branch {
                        TerminalRule()
                        Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.secondary).lineLimit(2)
                            .truncationMode(.middle).fixedSize(horizontal: false, vertical: true).help(branch)
                    }
                    if agent.archived == true || agent.state == "exited" || workspaceBucket(agent.state) == 3 && agent.state != "idle" {
                        Text(agent.archived == true ? "Arquivado" : liveStateTitle(agent.state))
                            .font(TerminalTheme.ui(11)).foregroundStyle(TerminalTheme.muted)
                    }
                }.padding(.leading, 22)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(WorkspaceCardStyle(state: agent.state))
            .help("#\(agent.id) · \(agent.name) · \(liveStateTitle(agent.state))\n\(agent.task)")
            .accessibilityLabel("Abrir \(agent.name), agente \(agent.id), \(agent.kind), \(liveStateTitle(agent.state))")
    }

    private var agentList: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TerminalListHeading()
                    ForEach(Array(Set(filtered.map(\.project))).sorted(), id: \.self) { path in
                        let agents = filtered.filter { $0.project == path }
                        HStack(spacing: 8) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .foregroundStyle(TerminalTheme.projectColor(path)).lineLimit(1).truncationMode(.middle)
                            Text("› \(agents.count)").foregroundStyle(TerminalTheme.muted)
                        }.font(TerminalTheme.mono(13, weight: .semibold))
                            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4).help(path)
                        ForEach(agents) { agent in
                            TerminalAgentRow(number: String(agent.id), name: agent.name, state: agent.state,
                                             elapsed: workspaceLifetime(agent), provider: agent.kind,
                                             activity: (agent.archived == true ? "Arquivado · " : "") +
                                                (agent.activity.isEmpty ? agent.task : agent.activity)) { open(agent) }
                        }
                    }
                }.frame(width: max(800, geometry.size.width - 48), alignment: .topLeading)
                    .frame(minHeight: max(0, geometry.size.height - 12), alignment: .topLeading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
    }

    private func newAgent() { model.showOverview(); composerID = UUID() }
    private func didStart(_ reference: DeliveryAgentReference, _ projectID: UUID) {
        selectedPanel = "terminal"; panelRequestID = UUID(); selectedProjectID = projectID; taskProjectID = projectID
        model.didStart(reference, projectID: projectID)
    }
    private func open(_ agent: EngineAgent, panel: String = "terminal") {
        selectedPanel = panel; panelRequestID = UUID(); model.open(agent); selectedProjectID = model.navigation.selectedProjectID
        if let ref = agent.deliveryReference { Task { await model.workflow.opened(ref, panel: panel) } }
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
    case "paused": TerminalTheme.warning
    case "lost": TerminalTheme.danger
    case "working": TerminalTheme.accent
    case "done": TerminalTheme.positive
    default: TerminalTheme.secondary
    }
}

func liveStateSymbol(_ state: String) -> String {
    switch state {
    case "paused": "exclamationmark.circle"
    case "lost": "bolt.slash.circle"
    case "working": "circle.lefthalf.filled"
    case "done": "checkmark.circle"
    case "idle": "circle.dotted"
    case "exited": "stop.circle"
    default: "questionmark.circle"
    }
}

private func workspaceBucket(_ state: String) -> Int {
    switch state {
    case "paused", "lost": 0
    case "working": 1
    case "done": 2
    default: 3
    }
}

private func workspaceLifetime(_ agent: EngineAgent) -> String {
    guard let created = agent.createdAtMs, created > 0 else { return "#\(agent.id)" }
    let seconds = max(0, Int(Date().timeIntervalSince1970 - Double(created) / 1000))
    if seconds >= 3600 { return "\(seconds / 3600)h\((seconds % 3600) / 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m\(seconds % 60)s" }
    return "\(seconds)s"
}
