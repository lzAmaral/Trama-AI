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
        .defaultSize(width: 1100, height: 720)
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
private final class WorkspaceModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedID: UUID?
    @Published var showsDemo = true
    @Published var errorMessage: String?
    @Published private(set) var canSave = false

    private let repository = ProjectRepository(fileURL: ProjectRepository.defaultFileURL)

    var selectedProject: Project? {
        projects.first { $0.id == selectedID }
    }

    init() { reload() }

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
            let project = try ProjectRegistration.project(for: selectedURL, existing: projects)
            if projects.contains(where: { $0.id == project.id }) {
                selectedID = project.id
                return
            }
            let updated = projects + [project]
            try repository.save(updated)
            projects = updated
            selectedID = project.id
        } catch {
            errorMessage = "Não foi possível adicionar o projeto. A lista anterior foi mantida.\n\n\(error.localizedDescription)"
        }
    }
}

private struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var showsEngine = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
            } detail: {
                Group {
                    if !workspace.canSave {
                        loadError
                    } else {
                        AgentBoardView(projects: workspace.projects,
                                       selectedProjectID: $workspace.selectedID,
                                       showsDemo: workspace.showsDemo)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TerminalTheme.background)
            }
            TerminalRule()
            HStack(spacing: 12) {
                Text("trama >").foregroundStyle(TerminalTheme.accent)
                Text("0 processos reais")
                Spacer()
                Text(workspace.canSave ? "local" : "gravação suspensa")
                Text("⌘O adicionar projeto")
            }
            .font(TerminalTheme.mono(12))
            .foregroundStyle(TerminalTheme.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(TerminalTheme.sidebar)
        }
        .font(TerminalTheme.mono(13))
        .foregroundStyle(TerminalTheme.primary)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Motor", systemImage: "cpu") { showsEngine = true }
                    .help("Verificar motor local e provedores instalados")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Demonstração", isOn: $workspace.showsDemo)
                    .font(TerminalTheme.mono(12))
                    .toggleStyle(.switch)
                    .help("Exibe agentes e atividades fictícios para explorar a interface.")
            }
        }
        .sheet(isPresented: $showsEngine) { EngineInspectorView() }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("trama").foregroundStyle(TerminalTheme.primary)
                    Text(">").foregroundStyle(TerminalTheme.accent)
                }
                .font(TerminalTheme.mono(24, weight: .semibold))
                Text("projetos / agentes")
                    .font(TerminalTheme.mono(12))
                    .foregroundStyle(TerminalTheme.secondary)
            }
            .padding(20)
            TerminalRule()
            List(selection: $workspace.selectedID) {
                Label("Visão geral", systemImage: "rectangle.split.3x1")
                    .font(TerminalTheme.mono(13))
                    .tag(Optional<UUID>.none)
                Section("projetos [\(workspace.projects.count)]") {
                    ForEach(workspace.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .font(TerminalTheme.mono(13))
                            .lineLimit(1)
                            .help(project.path)
                            .tag(Optional(project.id))
                            .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            TerminalRule()
            Button(action: workspace.chooseProject) {
                Label("Adicionar projeto", systemImage: "plus")
                    .font(TerminalTheme.mono(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(12)
            .disabled(!workspace.canSave)
        }
        .background(TerminalTheme.sidebar)
    }

    private var loadError: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("[erro] Não foi possível abrir os projetos")
                    .font(TerminalTheme.mono(20, weight: .medium))
                    .foregroundStyle(TerminalTheme.warning)
                Text("A gravação está suspensa para preservar seus dados. Verifique o arquivo de projetos e tente novamente.")
                    .foregroundStyle(TerminalTheme.secondary)
                Text(ProjectRepository.defaultFileURL.path)
                    .font(TerminalTheme.mono(12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Tentar novamente", action: workspace.reload)
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ProjectRepository.defaultFileURL])
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
