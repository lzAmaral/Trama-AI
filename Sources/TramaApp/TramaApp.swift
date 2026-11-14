import AppKit
import SwiftUI
import TramaCore

@main
struct TramaApp: App {
    @StateObject private var workspace = WorkspaceModel()

    var body: some Scene {
        WindowGroup("Trama") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 820, minHeight: 560)
                .preferredColorScheme(.dark)
                .tint(TerminalTheme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Adicionar projeto…", action: workspace.chooseProject)
                    .keyboardShortcut("o")
                    .disabled(!workspace.canSave)
            }
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedID: UUID?
    @Published var showsDemo = false
    @Published var errorMessage: String?
    @Published private(set) var canSave = false

    private let repository: ProjectRepository

    var projectStoreURL: URL { repository.fileURL }

    var selectedProject: Project? {
        projects.first { $0.id == selectedID }
    }

    init(repository: ProjectRepository = ProjectRepository(fileURL: ProjectRepository.defaultFileURL)) {
        self.repository = repository
        reload()
    }

    func reload() {
        do {
            projects = try repository.load()
            if !projects.contains(where: { $0.id == selectedID }) {
                selectedID = nil
            }
            canSave = true
        } catch {
            canSave = false
            errorMessage = "Não foi possível carregar seus projetos. Os dados existentes foram preservados.\n\n\(error.localizedDescription)"
        }
    }

    func chooseProject() {
        guard canSave else { return }
        let panel = NSOpenPanel()
        panel.title = "Adicionar projeto ao Trama"
        panel.message = "Escolha a pasta do projeto. Nenhum arquivo será alterado."
        panel.prompt = "Adicionar projeto"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let registration = try repository.register(selectedURL)
            projects = registration.projects
            selectedID = registration.project.id
        } catch {
            errorMessage = "Não foi possível adicionar o projeto. A lista anterior foi mantida.\n\n\(error.localizedDescription)"
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @StateObject private var live: LiveWorkspaceModel
    private let preferredSidebarWidth: CGFloat
    @State private var showsEngine = false
    @State private var showsHelp = false
    @State private var showsNewSession = false
    @State private var newSession = ""
    @State private var expandedSessions: Set<String> = []
    @State private var usageProvider: EngineProvider?
    @State private var usageSnapshots: [String: EngineUsage] = [:]

    init(workspace: WorkspaceModel, live: LiveWorkspaceModel = LiveWorkspaceModel(), preferredSidebarWidth: CGFloat = 248) {
        self.workspace = workspace
        _live = StateObject(wrappedValue: live)
        self.preferredSidebarWidth = min(380, max(200, preferredSidebarWidth))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: preferredSidebarWidth, max: 380)
            } detail: {
                Group {
                    if !workspace.canSave {
                        loadError
                    } else if !workspace.showsDemo {
                        LiveWorkspaceView(projects: workspace.projects, selectedProjectID: $workspace.selectedID, model: live,
                                          onAddProject: workspace.chooseProject)
                    } else {
                        AgentBoardView(projects: workspace.projects,
                                       selectedProjectID: $workspace.selectedID,
                                       showsDemo: workspace.showsDemo)
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(TerminalTheme.background)
            }
            TerminalRule()
            HStack(spacing: 8) {
                Image(systemName: workspace.showsDemo ? "play.rectangle" : "externaldrive")
                Text(workspace.showsDemo ? "Demonstração · dados fictícios" : (live.connectionError == nil ? "Motor local" : "Motor indisponível"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(workspace.canSave ? "Fechar uma aba mantém o agente em execução" : "Gravação de projetos suspensa")
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(TerminalTheme.ui(11))
            .foregroundStyle(TerminalTheme.secondary)
            .padding(.horizontal, 16)
            .frame(height: 26)
            .background(TerminalTheme.sidebar)
        }
        .font(TerminalTheme.ui(13))
        .task {
            live.configure(projects: workspace.projects)
            if let id = live.navigation.selectedProjectID, workspace.projects.contains(where: { $0.id == id }) {
                workspace.selectedID = id
            }
            while !Task.isCancelled {
                await live.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: workspace.projects) { _, projects in live.configure(projects: projects) }
        .onChange(of: workspace.selectedID) { _, id in
            if live.navigation.selectedProjectID != id { live.selectProject(id) }
        }
        .onChange(of: live.navigation.selectedProjectID) { _, id in
            if workspace.selectedID != id { workspace.selectedID = id }
        }
        .foregroundStyle(TerminalTheme.primary)
        .sheet(isPresented: $showsEngine) { EngineInspectorView() }
        .sheet(isPresented: $showsHelp) { helpPanel }
        .sheet(item: $usageProvider) { provider in
            UsageInspectorView(provider: provider, onUpdated: { usageSnapshots[provider.id] = $0 })
        }
        .onAppear {
            if let name = live.navigation.selectedSession { expandedSessions.insert(name) }
        }
        .onChange(of: live.navigation.selectedSession) { _, name in
            if let name { expandedSessions.insert(name) }
        }
        .alert("Nova sessão", isPresented: $showsNewSession) {
            TextField("Nome da sessão", text: $newSession)
            Button("Cancelar", role: .cancel) { }
            Button("Criar") {
                let name = newSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await live.perform {
                    try await live.client.createSession(name: name)
                    live.selectSession(name)
                    expandedSessions.insert(name)
                } }
            }.disabled(newSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || live.busy)
        } message: { Text("Uma sessão agrupa agentes de vários projetos. O destino de cada tarefa é escolhido no compositor.") }
        .alert("Atenção aos dados do projeto", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(">").font(TerminalTheme.mono(36, weight: .semibold))
                    .foregroundStyle(TerminalTheme.accent).frame(width: 52, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trama").font(TerminalTheme.ui(24, weight: .bold))
                    Text("local · macOS").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.muted)
                }
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.showsDemo ? "Demonstração" : "Sessões")
                        .font(TerminalTheme.mono(10, weight: .medium)).foregroundStyle(TerminalTheme.muted)
                        .padding(.horizontal, 12).padding(.bottom, 4)
                    if workspace.showsDemo {
                        Text("Dados fictícios").font(TerminalTheme.ui(13)).foregroundStyle(TerminalTheme.warning)
                            .padding(12)
                        Text("Use o filtro de projetos para explorar os exemplos.")
                            .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary).padding(.horizontal, 12)
                    } else {
                        Button { live.selectSession(nil) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.stack").frame(width: 16)
                                Text("Todas as sessões").lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(live.agents.count)").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.muted)
                            }.padding(.horizontal, 10).frame(height: 34)
                                .background(live.navigation.selectedSession == nil ? TerminalTheme.raised : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(live.busy)
                            .accessibilityAddTraits(live.navigation.selectedSession == nil ? .isSelected : [])
                        ForEach(live.sessions, id: \.self) { name in sessionRow(name) }
                        if !live.hasLoaded { ProgressView("Carregando…").controlSize(.small).padding(12) }
                        Button {
                            newSession = ""; showsNewSession = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").frame(width: 16)
                                Text("Nova sessão")
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 10).frame(height: 34)
                        }.buttonStyle(.plain).foregroundStyle(TerminalTheme.secondary).disabled(live.busy)
                    }
                }.padding(.horizontal, 12)
            }
            if !workspace.showsDemo { usagePanel.padding(.horizontal, 12).padding(.top, 16) }
            HStack(spacing: 16) {
                Button(action: workspace.chooseProject) { Image(systemName: "folder.badge.plus") }
                    .disabled(!workspace.canSave).help("Adicionar projeto (⌘O)").accessibilityLabel("Adicionar projeto")
                Button { showsHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .help("Como usar").accessibilityLabel("Como usar o Trama")
                Button { showsEngine = true } label: { Image(systemName: "gearshape") }
                    .help("Motor e provedores").accessibilityLabel("Motor e provedores")
                Spacer(minLength: 0)
                Toggle(isOn: $workspace.showsDemo) { Image(systemName: "play.rectangle") }
                    .toggleStyle(.button).buttonStyle(.plain)
                    .foregroundStyle(workspace.showsDemo ? TerminalTheme.warning : TerminalTheme.secondary)
                    .help("Demonstração com dados fictícios").accessibilityLabel("Demonstração")
            }.font(TerminalTheme.ui(14)).buttonStyle(.plain).foregroundStyle(TerminalTheme.secondary)
                .padding(20)
        }.font(TerminalTheme.ui(13)).background(TerminalTheme.sidebar)
    }

    private func sessionRow(_ name: String) -> some View {
        let agents = live.agents.filter { $0.session == name && $0.archived != true }
        let selected = live.navigation.selectedSession == name
        let expanded = expandedSessions.contains(name)
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    if expanded { expandedSessions.remove(name) } else { expandedSessions.insert(name) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(TerminalTheme.ui(9, weight: .semibold)).frame(width: 16, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "Recolher" : "Expandir") sessão \(name)")
                Button {
                    live.selectSession(name); expandedSessions.insert(name)
                } label: {
                    HStack {
                        Text(name).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .fontWeight(selected ? .semibold : .regular).help(name)
                        Spacer(minLength: 0)
                        Text("\(agents.count)").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.muted)
                    }.frame(minHeight: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Sessão \(name), \(agents.count) agentes")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }.padding(.leading, 6).padding(.trailing, 10)
                .background(selected ? TerminalTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            if expanded {
                ForEach(agents) { agent in
                    Button { live.open(agent) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: liveStateSymbol(agent.state)).frame(width: 12)
                                .foregroundStyle(liveStateColor(agent.state))
                            Text(agent.kind == "terminal" ? "$" : String(agent.kind.prefix(1)).uppercased())
                                .foregroundStyle(TerminalTheme.providerColor(agent.kind)).frame(width: 12)
                            Text(agent.name).lineLimit(1).truncationMode(.middle).foregroundStyle(agent.state == "paused" ? TerminalTheme.warning : TerminalTheme.secondary)
                            Spacer(minLength: 0)
                        }.font(TerminalTheme.mono(11)).padding(.leading, 22).padding(.trailing, 8).frame(height: 28)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("\(agent.name) · #\(agent.id)\n\(agent.project)\n\(agent.task)")
                        .accessibilityLabel("Abrir \(agent.name), \(liveStateTitle(agent.state)), \(agent.kind)")
                }
            }
        }.disabled(live.busy)
    }

    private var usagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TerminalRule()
            HStack {
                Text("Plano e consumo").font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
                Spacer()
                Menu {
                    let supported: Set<String> = ["claude", "codex", "kilo", "opencode", "antigravity", "grok", "kimi"]
                    ForEach(live.providers.filter { supported.contains($0.id) }) { provider in
                        Button(provider.id) { usageProvider = provider }
                    }
                    Divider()
                    Button("Motor e provedores…") { showsEngine = true }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(TerminalTheme.secondary)
                .fixedSize().accessibilityLabel("Consultar consumo manualmente")
            }
            if usageSnapshots.isEmpty {
                Text("Consulte um provedor para exibir os limites aqui.")
                    .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary)
            }
            if !usageSnapshots.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(usageSnapshots.keys.sorted(), id: \.self) { kind in
                            if let usage = usageSnapshots[kind] {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(kind).font(TerminalTheme.mono(12, weight: .semibold)).foregroundStyle(TerminalTheme.providerColor(kind))
                                    if let limits = usage.limits {
                                        if let window = limits.session { usageWindow("Janela", window) }
                                        if let window = limits.weekly { usageWindow("Semana", window) }
                                        if let window = limits.monthly { usageWindow("Mês", window) }
                                        if let credits = limits.credits { Text("Saldo: \(credits, specifier: "%.2f")").font(TerminalTheme.mono(11)) }
                                    }
                                    if let problem = usage.problem { Text(problem).font(TerminalTheme.ui(11)).foregroundStyle(TerminalTheme.warning).lineLimit(2) }
                                    Text(Date(timeIntervalSince1970: Double(usage.updatedAtMs) / 1000), format: .dateTime.hour().minute())
                                        .font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }.frame(height: min(CGFloat(usageSnapshots.count) * 176, 240))
            }
        }
    }

    private func usageWindow(_ title: String, _ window: EngineUsageWindow) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(window.usedPercent, specifier: "%.0f")%")
            }.font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.secondary)
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .tint(window.usedPercent >= 90 ? TerminalTheme.danger : window.usedPercent >= 70 ? TerminalTheme.warning : TerminalTheme.positive)
                .accessibilityLabel("Consumo \(title)").accessibilityValue(Text("\(window.usedPercent, specifier: "%.0f") por cento"))
        }
    }

    private var helpPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Como usar o Trama").font(TerminalTheme.ui(22, weight: .semibold))
                Spacer()
                Button("Fechar") { showsHelp = false }.keyboardShortcut(.cancelAction)
            }
            Text("1. Escolha ou crie uma sessão na barra lateral.")
            Text("2. No compositor, escolha o provedor e a pasta do projeto.")
            Text("3. Escreva a tarefa e use ⌘Return para iniciar.")
            Text("Abra um cartão ou uma aba para acompanhar o terminal. Responda às aprovações diretamente no terminal do provedor.")
                .foregroundStyle(TerminalTheme.secondary)
            TerminalRule()
            Text("⌘O  Adicionar projeto\n⌘F  Buscar agentes\n⌘N  Nova tarefa\n⌘⇧I  Inbox\n⌘⇧N  Próxima intervenção\n⌘W  Fechar aba")
                .font(TerminalTheme.mono(12))
            Text("Fechar uma aba ou o aplicativo mantém os processos em execução. Encerrar um agente exige uma ação própria e confirmação.")
                .foregroundStyle(TerminalTheme.secondary)
        }.font(TerminalTheme.ui(13)).padding(24).frame(width: 560)
            .foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
    }

    private var loadError: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Não foi possível abrir os projetos")
                    .font(TerminalTheme.ui(20, weight: .medium))
                    .foregroundStyle(TerminalTheme.warning)
                Text("A gravação está suspensa para preservar seus dados. Verifique o arquivo de projetos e tente novamente.")
                    .foregroundStyle(TerminalTheme.secondary)
                Text(workspace.projectStoreURL.path)
                    .font(TerminalTheme.mono(12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Tentar novamente", action: workspace.reload)
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([workspace.projectStoreURL])
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
