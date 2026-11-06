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
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trama").font(.title2.weight(.semibold))
                        Text("Seu espaço de criação").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)

                List(selection: $workspace.selectedID) {
                    Section("Projetos · \(workspace.projects.count)") {
                        ForEach(workspace.projects) { project in
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1)
                                .help(project.path)
                                .tag(project.id)
                                .padding(.vertical, 5)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                Button(action: workspace.chooseProject) {
                    Label("Adicionar projeto", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(18)
                .disabled(!workspace.canSave)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            if !workspace.canSave {
                ContentUnavailableView {
                    Label("Não foi possível abrir os projetos", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("A gravação está suspensa para preservar seus dados. Verifique o arquivo de projetos e tente novamente.")
                    Text(ProjectRepository.defaultFileURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } actions: {
                    Button("Tentar novamente", action: workspace.reload)
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ProjectRepository.defaultFileURL])
                    }
                }
            } else if let project = workspace.selectedProject {
                ProjectDashboard(project: project, showsDemo: workspace.showsDemo)
            } else {
                ContentUnavailableView {
                    Label("Seu próximo projeto começa aqui", systemImage: "folder.badge.plus")
                } description: {
                    Text("Adicione uma pasta para organizar seu trabalho no Trama.\nSeus arquivos permanecem onde estão.")
                } actions: {
                    Button("Adicionar projeto…", action: workspace.chooseProject)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Demonstração", isOn: $workspace.showsDemo)
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
}

private struct ProjectDashboard: View {
    let project: Project
    let showsDemo: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ESPAÇO DE TRABALHO")
                        .font(.caption.weight(.semibold)).tracking(1.6)
                        .foregroundStyle(.secondary)
                    Text(project.name).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                    Label(project.path, systemImage: "folder")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }

                if showsDemo {
                    Label("Demonstração — nenhum agente em execução", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 12) {
                        MetricView(value: "3", title: "Agentes de exemplo", symbol: "person.2")
                        MetricView(value: "1", title: "Em execução fictícia", symbol: "circle.dotted")
                        MetricView(value: "1", title: "Atenção fictícia", symbol: "hand.raised")
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Agentes").font(.title2.weight(.semibold))
                        VStack(spacing: 0) {
                            AgentRow(name: "Interface", task: "Explorando a navegação de \(project.name)", status: .working, symbol: "rectangle.3.group")
                            Divider().padding(.leading, 58)
                            AgentRow(name: "Revisão", task: "Exemplo de solicitação de revisão", status: .needsAttention, symbol: "text.magnifyingglass")
                            Divider().padding(.leading, 58)
                            AgentRow(name: "Planejamento", task: "Exemplo de escopo organizado", status: .completed, symbol: "checklist")
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Atividade").font(.title2.weight(.semibold))
                            Spacer()
                            Text("Exemplos fictícios").font(.caption).foregroundStyle(.secondary)
                        }
                        ActivityRow(symbol: "hand.raised", title: "Revisão solicitou uma decisão", detail: "Uma solicitação real aparecerá aqui quando houver integração.", color: .orange)
                        ActivityRow(symbol: "square.and.pencil", title: "Interface registrou uma etapa", detail: "Nenhum arquivo de \(project.name) foi alterado.", color: .blue)
                        ActivityRow(symbol: "checkmark.circle", title: "Planejamento concluiu uma tarefa", detail: "Este histórico ilustra a organização das atividades.", color: .green)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Nenhum agente conectado", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("A integração com agentes será adicionada em uma próxima etapa. Ative Demonstração para explorar a interface com exemplos fictícios.")
                    }
                    .frame(minHeight: 310)
                }
            }
            .padding(32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MetricView: View {
    let value: String
    let title: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .medium, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

private struct AgentRow: View {
    let name: String
    let task: String
    let status: AgentStatus
    let symbol: String

    private var color: Color {
        switch status {
        case .working: .blue
        case .needsAttention: .orange
        case .completed: .green
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30, height: 34)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.headline)
                Text(task).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label(status.title, systemImage: status == .completed ? "checkmark.circle.fill" : status == .needsAttention ? "exclamationmark.circle.fill" : "circle.dotted")
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .fixedSize()
        }
        .padding(16)
    }
}

private struct ActivityRow: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
