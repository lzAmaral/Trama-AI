import SwiftUI
import TramaCore

struct NewAgentView: View {
    @ObservedObject var model: LiveWorkspaceModel
    let projects: [Project]
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var kind = "terminal"
    @State private var name = "nova-tarefa"
    @State private var task = ""
    @State private var session: String?
    @State private var isolate = false
    @State private var skills: [EngineSkill] = []
    @State private var loadingSkills = false
    @State private var skillError: String?
    @FocusState private var nameFocused: Bool

    private var sessionSelection: EngineSessionSelection {
        EngineSessionSelection(sessions: model.sessions, preferredSession: session)
    }

    init(model: LiveWorkspaceModel, projects: [Project], initialProjectID: UUID?, initialSession: String) {
        self.model = model
        self.projects = projects
        _projectID = State(initialValue: initialProjectID ?? projects.first?.id)
        _session = State(initialValue: EngineSessionSelection(sessions: model.sessions,
                                                            preferredSession: initialSession).selectedSession)
    }

    private var selectedProject: Project? { projects.first { $0.id == projectID } }
    private var valid: Bool {
        selectedProject != nil && sessionSelection.selectedSession != nil &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        model.providers.contains { $0.id == kind && $0.installed } && (kind == "terminal" || !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("trama > nova tarefa").font(TerminalTheme.mono(20, weight: .medium))
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
            Form {
                Picker("Projeto", selection: $projectID) {
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Provedor", selection: $kind) {
                    ForEach(model.providers) { Text($0.id).tag($0.id) }
                }
                Picker("Sessão", selection: Binding(
                    get: { sessionSelection.selectedSession },
                    set: { session = $0 }
                )) {
                    if sessionSelection.options.isEmpty {
                        Text("Nenhuma sessão disponível").tag(nil as String?)
                    }
                    ForEach(sessionSelection.options, id: \.self) { Text($0).tag(Optional($0)) }
                }.disabled(sessionSelection.options.isEmpty)
                TextField("Nome", text: $name).focused($nameFocused)
                Toggle("Isolar em um worktree Git", isOn: $isolate)
            }.disabled(model.busy)
            if sessionSelection.options.isEmpty {
                Text("Crie uma sessão no quadro antes de iniciar uma tarefa.")
                    .foregroundStyle(TerminalTheme.warning)
            }
            if model.loadingProviders { ProgressView("Verificando provedores locais…") }
            if let error = model.providerError {
                Text("Não foi possível detectar provedores: \(error)").foregroundStyle(TerminalTheme.warning).textSelection(.enabled)
                Button("Verificar provedores novamente") { Task { await model.loadProviders() } }.disabled(model.loadingProviders)
            } else if model.providers.isEmpty && !model.loadingProviders {
                Text("Nenhum provedor instalado foi detectado. Verifique o motor local.").foregroundStyle(TerminalTheme.warning)
            }
            Text(kind == "terminal" ? "Comando inicial (opcional)" : "Tarefa")
            TextEditor(text: $task)
                .font(TerminalTheme.mono(13))
                .accessibilityLabel(kind == "terminal" ? "Comando inicial opcional" : "Tarefa do agente")
                .disabled(model.busy)
                .frame(minHeight: 100, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(TerminalTheme.border))
            if kind != "terminal" {
                Button(loadingSkills ? "Lendo skills…" : "Carregar skills do projeto") {
                    Task { await loadSkills() }
                }.disabled(loadingSkills || selectedProject == nil || model.busy)
                if let skillError { Text(skillError).foregroundStyle(TerminalTheme.warning) }
                if !skills.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                                Button {
                                    task = skill.invocation
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(skill.name)
                                        Text(skill.description).font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered).disabled(model.busy)
                            }
                        }
                    }.frame(maxHeight: 110)
                }
            }
            Text(kind == "terminal"
                 ? "O terminal executa comandos na pasta escolhida. Você poderá interagir e encerrá-lo pelo Trama."
                 : "O CLI usará seu login existente e poderá enviar dados ao provedor. As aprovações do CLI permanecem ativas no terminal.")
                .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.secondary)
            if let error = model.error { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(4) }
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Iniciar sessão") {
                    guard valid, !model.busy, let project = selectedProject,
                          let requestedSession = sessionSelection.selectedSession else { return }
                    let requestedKind = kind
                    let requestedName = name
                    let requestedTask = task
                    let requestedIsolation = isolate
                    Task {
                        await model.perform {
                            _ = try await model.client.start(kind: requestedKind, cwd: project.path, name: requestedName,
                                                             task: requestedTask, session: requestedSession, isolate: requestedIsolation)
                            dismiss()
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!valid || model.busy)
            }
        }
        .padding(24).frame(width: 600)
        .font(TerminalTheme.mono(13))
        .background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.busy)
        .onAppear { nameFocused = true; selectAvailableProvider() }
        .onChange(of: model.sessions, initial: true) { _, _ in session = sessionSelection.selectedSession }
        .onChange(of: model.providers) { _, _ in selectAvailableProvider() }
        .onChange(of: kind) { _, _ in skills = []; skillError = nil }
        .onChange(of: projectID) { _, _ in skills = []; skillError = nil }
    }

    private func selectAvailableProvider() {
        if !model.providers.contains(where: { $0.id == kind }), let first = model.providers.first { kind = first.id }
    }

    @MainActor private func loadSkills() async {
        guard !loadingSkills, let project = selectedProject else { return }
        let requestedKind = kind
        loadingSkills = true
        defer { loadingSkills = false }
        do {
            let result = try await model.client.skills(kind: requestedKind, cwd: project.path)
            if requestedKind == kind && project.id == projectID {
                skills = result
                skillError = result.isEmpty ? "Nenhuma skill encontrada para este projeto e provedor." : nil
            }
        } catch is CancellationError { } catch {
            if requestedKind == kind && project.id == projectID { skillError = error.localizedDescription }
        }
    }
}
