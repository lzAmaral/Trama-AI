import SwiftUI
import TramaCore

struct NewAgentView: View {
    @ObservedObject var model: LiveWorkspaceModel
    let projects: [Project]
    let onStarted: (DeliveryAgentReference, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var kind = ""
    @State private var name = ""
    @State private var creating = false
    @State private var creationFailed = false
    @State private var session: String?
    @State private var isolate = false
    @State private var skills: [EngineSkill] = []
    @State private var loadingSkills = false
    @State private var skillError: String?
    @FocusState private var taskFocused: Bool

    private var sessionSelection: EngineSessionSelection {
        EngineSessionSelection(sessions: model.sessions, preferredSession: session)
    }

    init(model: LiveWorkspaceModel, projects: [Project], initialProjectID: UUID?, initialSession: String,
         onStarted: @escaping (DeliveryAgentReference, UUID) -> Void = { _, _ in }) {
        self.model = model
        self.projects = projects
        self.onStarted = onStarted
        _projectID = State(initialValue: initialProjectID)
        _session = State(initialValue: EngineSessionSelection(sessions: model.sessions,
                                                            preferredSession: initialSession).selectedSession)
    }

    private var selectedProject: Project? { projects.first { $0.id == projectID } }
    private var isBusy: Bool { model.busy || creating }
    private var taskDraft: Binding<String> {
        Binding(get: { selectedProject.flatMap { model.projectTaskDrafts[$0.id] } ?? "" },
                set: { text in
                    if let project = selectedProject { model.projectTaskDrafts[project.id] = text }
                })
    }
    private var task: String { taskDraft.wrappedValue }
    private var valid: Bool {
        selectedProject != nil && sessionSelection.selectedSession != nil &&
        model.providers.contains { $0.id == kind && $0.installed } && (kind == "terminal" || !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Novo agente").font(TerminalTheme.mono(20, weight: .medium))
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
            }
            Form {
                Picker("Projeto", selection: $projectID) {
                    Text("Selecione um projeto").tag(nil as UUID?)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Provedor", selection: $kind) {
                    if kind.isEmpty { Text("Selecionar provedor").tag("") }
                    ForEach(model.providers.filter(\.installed)) { Text($0.id == "terminal" ? "Shell" : $0.id).tag($0.id) }
                }
                DisclosureGroup("Opções avançadas") {
                    Picker("Sessão", selection: Binding(
                        get: { sessionSelection.selectedSession }, set: { session = $0 }
                    )) {
                        if sessionSelection.options.isEmpty {
                            Text("Nenhuma sessão disponível").tag(nil as String?)
                        }
                        ForEach(sessionSelection.options, id: \.self) { Text($0).tag(Optional($0)) }
                    }.disabled(sessionSelection.options.isEmpty)
                    TextField("Nome do agente (opcional)", text: $name)
                    Toggle("Isolar em um worktree Git", isOn: $isolate)
                }
            }.disabled(isBusy)
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
            if let project = selectedProject {
                Text("Destino: \(project.name) · \(project.path)")
                    .foregroundStyle(TerminalTheme.secondary).textSelection(.enabled)
            } else {
                Text("Selecione explicitamente o projeto de destino.").foregroundStyle(TerminalTheme.warning)
            }
            Text(kind == "terminal" ? "Comando inicial (opcional)" : "Tarefa do agente")
            TextEditor(text: taskDraft)
                .font(TerminalTheme.mono(13))
                .accessibilityLabel(kind == "terminal" ? "Comando inicial opcional" : "Tarefa do agente")
                .focused($taskFocused)
                .disabled(isBusy)
                .disabled(selectedProject == nil)
                .frame(minHeight: 100, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if task.isEmpty {
                        Text(kind == "terminal" ? "Comando opcional para o shell…" : "Descreva o que o agente deve fazer…")
                            .foregroundStyle(TerminalTheme.secondary).padding(6).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(TerminalTheme.border))
            if kind != "terminal" {
                Button(loadingSkills ? "Lendo skills…" : "Carregar skills do projeto") {
                    Task { await loadSkills() }
                }.disabled(loadingSkills || selectedProject == nil || isBusy)
                if let skillError { Text(skillError).foregroundStyle(TerminalTheme.warning) }
                if !skills.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                                Button {
                                    taskDraft.wrappedValue = skill.invocation
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(skill.name)
                                        Text(skill.description).font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered).disabled(isBusy)
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
            if creationFailed {
                Text("Tarefa preservada. Atualize o quadro antes de tentar de novo: o agente pode ter sido criado.")
                    .foregroundStyle(TerminalTheme.warning)
            }
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Iniciar agente", action: start)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!valid || isBusy)
            }
        }
        .padding(24).frame(width: 600)
        .font(TerminalTheme.mono(13))
        .background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
        .onAppear { selectAvailableProvider(); taskFocused = selectedProject != nil }
        .onChange(of: model.sessions, initial: true) { _, _ in session = sessionSelection.selectedSession }
        .onChange(of: model.providers) { _, _ in selectAvailableProvider() }
        .onChange(of: kind) { _, _ in skills = []; skillError = nil }
        .onChange(of: projectID) { _, id in
            skills = []; skillError = nil; creationFailed = false; taskFocused = id != nil
        }
    }

    private func start() {
        guard valid, !isBusy, let project = selectedProject,
              let requestedSession = sessionSelection.selectedSession else { return }
        let requestedKind = kind
        let requestedTask = task
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AgentTaskName.make(task: requestedTask, existingNames: model.agents.filter { $0.session == requestedSession }.map(\.name))
            : name
        let requestedIsolation = isolate
        creating = true
        creationFailed = false
        Task { @MainActor in
            defer { creating = false }
            await model.perform {
                let reference = try await model.client.startIdentified(kind: requestedKind, cwd: project.path, name: requestedName,
                                                                      task: requestedTask, session: requestedSession, isolate: requestedIsolation)
                if model.projectTaskDrafts[project.id] == requestedTask { model.projectTaskDrafts[project.id] = nil }
                onStarted(reference, project.id)
                dismiss()
            }
            creationFailed = model.error != nil
        }
    }

    private func selectAvailableProvider() {
        let installed = model.providers.filter(\.installed)
        if !installed.contains(where: { $0.id == kind }) {
            kind = installed.first(where: { $0.id != "terminal" })?.id ?? installed.first?.id ?? ""
        }
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
