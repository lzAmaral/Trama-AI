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
    @State private var newSessionProjectID: UUID?
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
                                          usageSnapshots: usageSnapshots, onConsultUsage: { usageProvider = $0 },
                                          onInspectEngine: { showsEngine = true }, onAddProject: workspace.chooseProject)
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
            await live.workflow.reload()
            while !Task.isCancelled {
                await live.refresh(showProgress: false)
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
        .alert("Nova sessão", isPresented: $showsNewSession) {
            TextField("Nome da sessão", text: $newSession)
            Button("Cancelar", role: .cancel) { }
            Button("Criar") {
                let name = newSession.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let projectID = newSessionProjectID
                Task { await live.perform {
                    try await live.client.createSession(name: name)
                    live.selectScope(projectID: projectID, session: name)
                } }
            }.disabled(newSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || live.busy)
        } message: { Text("Crie uma sessão e escreva a primeira tarefa no projeto selecionado. Confira a pasta junto da mensagem.") }
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
            HStack(alignment: .firstTextBaseline) {
                Text("trama").font(TerminalTheme.mono(28, weight: .bold))
                Spacer(minLength: 0)
                Text("local").font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.showsDemo ? "Demonstração" : "Projetos")
                        .font(TerminalTheme.mono(10, weight: .medium)).foregroundStyle(TerminalTheme.muted)
                        .padding(.horizontal, 12).padding(.bottom, 4)
                    if workspace.showsDemo {
                        Text("Dados fictícios").font(TerminalTheme.ui(13)).foregroundStyle(TerminalTheme.warning)
                            .padding(12)
                        Text("Use o filtro de projetos para explorar os exemplos.")
                            .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary).padding(.horizontal, 12)
                    } else {
                        ProjectSidebarView(projects: workspace.projects, model: live,
                                           addProject: workspace.chooseProject) { projectID in
                            newSessionProjectID = projectID
                            newSession = ""
                            showsNewSession = true
                        }

                    }
                }.padding(.horizontal, 12)
            }
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

    private var helpPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Como usar o Trama").font(TerminalTheme.ui(22, weight: .semibold))
                Spacer()
                Button("Fechar") { showsHelp = false }.keyboardShortcut(.cancelAction)
            }
            Text("1. Escolha um projeto na lateral e abra ou crie uma sessão.")
            Text("2. Escolha o provedor e confira a pasta junto do campo de mensagem.")
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
