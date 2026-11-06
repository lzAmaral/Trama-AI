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
                selectedID = projects.first?.id
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

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
            } detail: {
                Group {
                    if !workspace.canSave {
                        loadError
                    } else if let project = workspace.selectedProject {
                        ProjectDashboard(project: project, showsDemo: workspace.showsDemo)
                    } else {
                        emptyWorkspace
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
                Toggle("Demonstração", isOn: $workspace.showsDemo)
                    .font(TerminalTheme.mono(12))
                    .toggleStyle(.switch)
                    .help("Exibe agentes e atividades fictícios para explorar a interface.")
            }
        }
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
                Section("projetos [\(workspace.projects.count)]") {
                    ForEach(workspace.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .font(TerminalTheme.mono(13))
                            .lineLimit(1)
                            .help(project.path)
                            .tag(project.id)
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

    private var emptyWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("~/projetos").foregroundStyle(TerminalTheme.secondary)
                HStack(alignment: .top, spacing: 12) {
                    Text(">").foregroundStyle(TerminalTheme.accent)
                    Text("Um lugar para o seu próximo projeto")
                        .foregroundStyle(TerminalTheme.primary)
                }
                .font(TerminalTheme.mono(24, weight: .medium))
                TerminalRule()
                VStack(alignment: .leading, spacing: 12) {
                    Text("[info] Nenhuma pasta cadastrada")
                        .foregroundStyle(TerminalTheme.accent)
                    Text("Adicione uma pasta local para reunir seus projetos e explorar o painel de agentes.")
                        .foregroundStyle(TerminalTheme.secondary)
                    Text("Seus arquivos permanecem onde estão.")
                        .foregroundStyle(TerminalTheme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("Adicionar projeto…", action: workspace.chooseProject)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Text("A integração com agentes reais será adicionada em uma próxima etapa.")
                    .font(TerminalTheme.mono(12))
                    .foregroundStyle(TerminalTheme.secondary)
            }
            .padding(32)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

private struct ProjectDashboard: View {
    let project: Project
    let showsDemo: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("projeto selecionado")
                        .font(TerminalTheme.mono(12))
                        .foregroundStyle(TerminalTheme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(">").foregroundStyle(TerminalTheme.accent)
                        Text(project.name).textSelection(.enabled)
                    }
                    .font(TerminalTheme.mono(24, weight: .medium))
                    Text(project.path)
                        .font(TerminalTheme.mono(12))
                        .foregroundStyle(TerminalTheme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TerminalRule()
                if showsDemo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("[demo] Demonstração — nenhum agente em execução")
                            .foregroundStyle(TerminalTheme.warning)
                        Text("Agentes e eventos abaixo são fictícios")
                            .font(TerminalTheme.mono(12))
                            .foregroundStyle(TerminalTheme.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Text("3 agentes de exemplo · 1 em andamento · 1 aguardando · 1 concluído")
                        .font(TerminalTheme.mono(12))
                        .foregroundStyle(TerminalTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    agents
                    activity
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("[info] Nenhum agente conectado")
                            .foregroundStyle(TerminalTheme.accent)
                        Text("Ative Demonstração para explorar o painel com exemplos fictícios. A integração com agentes reais será adicionada em uma próxima etapa.")
                            .foregroundStyle(TerminalTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var agents: some View {
        VStack(spacing: 0) {
            TerminalPanelHeader(title: "agentes", detail: "exemplos")
            AgentRow(index: "01", name: "Interface", task: "Explorando a navegação de \(project.name)", status: .working)
            TerminalRule()
            AgentRow(index: "02", name: "Revisão", task: "Exemplo de solicitação de revisão", status: .needsAttention)
            TerminalRule()
            AgentRow(index: "03", name: "Planejamento", task: "Exemplo de escopo organizado", status: .completed)
        }
        .background(TerminalTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(TerminalTheme.border))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            TerminalPanelHeader(title: "atividade", detail: "log demonstrativo")
            VStack(alignment: .leading, spacing: 20) {
                ActivityRow(index: "001", level: "aguarda", title: "Revisão solicitou uma decisão", detail: "Uma solicitação real aparecerá aqui quando houver integração.", color: TerminalTheme.warning)
                ActivityRow(index: "002", level: "info", title: "Interface registrou uma etapa", detail: "Nenhum arquivo de \(project.name) foi alterado.", color: TerminalTheme.secondary)
                ActivityRow(index: "003", level: "ok", title: "Planejamento concluiu uma tarefa", detail: "Este histórico ilustra a organização das atividades.", color: TerminalTheme.accent)
            }
            .padding(16)
        }
        .background(TerminalTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(TerminalTheme.border))
    }
}

private struct TerminalPanelHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(TerminalTheme.primary)
                Spacer()
                Text(detail).foregroundStyle(TerminalTheme.secondary)
            }
            .font(TerminalTheme.mono(12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            TerminalRule()
        }
    }
}

private struct AgentRow: View {
    let index: String
    let name: String
    let task: String
    let status: AgentStatus

    private var color: Color {
        switch status {
        case .working: TerminalTheme.primary
        case .needsAttention: TerminalTheme.warning
        case .completed: TerminalTheme.accent
        }
    }

    private var symbol: String {
        switch status {
        case .working: "circle.dotted"
        case .needsAttention: "pause.circle"
        case .completed: "checkmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(TerminalTheme.mono(13, weight: .medium))
                Text(task)
                    .font(TerminalTheme.mono(12))
                    .foregroundStyle(TerminalTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Label(status.title, systemImage: symbol)
                .font(TerminalTheme.mono(12))
                .foregroundStyle(color)
                .fixedSize()
                .frame(width: 148, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(16)
    }
}

private struct ActivityRow: View {
    let index: String
    let level: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                (Text("[\(level)] ").foregroundColor(color) + Text(title).foregroundColor(TerminalTheme.primary))
                    .font(TerminalTheme.mono(12))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(TerminalTheme.mono(12))
                    .foregroundStyle(TerminalTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
    }
}
