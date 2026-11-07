import SwiftUI
import TramaCore

/// Inspired by Octo f66aa85 desktop/ui/index.html's persistent task composer (MIT).
/// Implemented natively; provider approvals remain in the interactive terminal.
struct ProjectTaskComposer: View {
    @ObservedObject var model: LiveWorkspaceModel
    let project: Project?
    let preferredSession: String
    let onStarted: (DeliveryAgentReference, UUID) -> Void
    @State private var kind = ""
    @State private var name = ""
    @State private var session: String?
    @State private var isolate = false
    @State private var creating = false
    @State private var showsOptions = false
    @State private var notice: String?
    @FocusState private var taskFocused: Bool

    init(model: LiveWorkspaceModel, project: Project?, preferredSession: String,
         onStarted: @escaping (DeliveryAgentReference, UUID) -> Void) {
        self.model = model
        self.project = project
        self.preferredSession = preferredSession
        self.onStarted = onStarted
    }

    private var providers: [EngineProvider] { model.providers.filter(\.installed) }
    private var sessionSelection: EngineSessionSelection {
        EngineSessionSelection(sessions: model.sessions, preferredSession: session ?? preferredSession)
    }
    private var draft: Binding<String> {
        Binding(get: { project.flatMap { model.projectTaskDrafts[$0.id] } ?? "" },
                set: { text in
                    if let project { model.projectTaskDrafts[project.id] = text }
                })
    }
    private var valid: Bool {
        project != nil && sessionSelection.selectedSession != nil &&
        providers.contains { $0.id == kind } &&
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !creating && !model.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: draft)
                    .font(TerminalTheme.mono(13))
                    .scrollContentBackground(.hidden).padding(4)
                    .accessibilityLabel("Tarefa para um novo agente")
                    .focused($taskFocused)
                    .disabled(project == nil || creating || model.busy)
                if draft.wrappedValue.isEmpty {
                    Text(project == nil ? "Selecione um projeto para escrever uma tarefa…" : "O que o agente deve fazer neste projeto?")
                        .foregroundStyle(TerminalTheme.secondary).padding(8).allowsHitTesting(false)
                }
            }
            .frame(height: 64).background(TerminalTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(TerminalTheme.border))
            HStack(spacing: 10) {
                Picker("Provedor", selection: $kind) {
                    if !providers.contains(where: { $0.id == kind }) { Text("Selecionar provedor").tag("") }
                    ForEach(providers) { Text($0.id == "terminal" ? "Shell" : $0.id).tag($0.id) }
                }.labelsHidden().frame(width: 120)
                    .accessibilityLabel("Provedor do novo agente")
                    .disabled(creating || model.busy || providers.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? "Selecione um projeto").lineLimit(1)
                    if let project {
                        Text(project.path).font(TerminalTheme.mono(10))
                            .foregroundStyle(TerminalTheme.secondary).lineLimit(1).truncationMode(.middle)
                            .help(project.path).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if creating { ProgressView().controlSize(.small) }
                Button("Iniciar agente", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).disabled(!valid)
            }
            DisclosureGroup("Opções avançadas", isExpanded: $showsOptions) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                    TextField("Nome do agente (opcional)", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Sessão", selection: Binding(
                        get: { sessionSelection.selectedSession }, set: { session = $0 }
                    )) {
                        if sessionSelection.options.isEmpty { Text("Nenhuma sessão disponível").tag(nil as String?) }
                        ForEach(sessionSelection.options, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Toggle("Isolar em um worktree Git", isOn: $isolate)
                    Text(kind == "terminal" ? "O shell executa a tarefa como comando na pasta indicada."
                         : "O agente usa seu login do provedor. Responda às aprovações no terminal.")
                        .foregroundStyle(TerminalTheme.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6).disabled(creating || model.busy)
                }.frame(minHeight: 40, idealHeight: 80, maxHeight: 96)
            }
            if project == nil {
                Text("Escolha explicitamente um projeto na barra lateral para iniciar.")
                    .foregroundStyle(TerminalTheme.secondary)
            } else if sessionSelection.selectedSession == nil {
                Text("Crie uma sessão antes de iniciar o agente.").foregroundStyle(TerminalTheme.warning)
            }
            if model.loadingProviders { ProgressView("Verificando provedores…").controlSize(.small) }
            if let error = model.providerError {
                HStack {
                    Text("Falha ao detectar provedores: \(error)").lineLimit(2)
                    Button("Verificar novamente") { Task { await model.loadProviders() } }
                        .disabled(model.loadingProviders)
                }.foregroundStyle(TerminalTheme.warning)
            } else if providers.isEmpty && !model.loadingProviders {
                Text("Nenhum provedor instalado disponível.").foregroundStyle(TerminalTheme.warning)
            }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.warning).lineLimit(2) }
        }
        .font(TerminalTheme.mono(11))
        .onAppear { selectProvider(); taskFocused = project != nil }
        .onChange(of: model.providers) { _, _ in selectProvider() }
        .onChange(of: project?.id) { _, id in notice = nil; taskFocused = id != nil }
    }

    private func selectProvider() {
        guard !providers.contains(where: { $0.id == kind }) else { return }
        kind = providers.first(where: { $0.id != "terminal" })?.id ?? providers.first?.id ?? ""
    }

    private func start() {
        guard valid, let project, let requestedSession = sessionSelection.selectedSession else { return }
        let requestedText = draft.wrappedValue
        let requestedKind = kind
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AgentTaskName.make(task: requestedText, existingNames: model.agents.filter { $0.session == requestedSession }.map(\.name))
            : name
        let requestedIsolation = isolate
        creating = true
        notice = nil
        Task { @MainActor in
            defer { creating = false }
            await model.perform {
                let id = try await model.client.startIdentified(kind: requestedKind, cwd: project.path, name: requestedName,
                                                      task: requestedText, session: requestedSession, isolate: requestedIsolation)
                // A successful creation must remain successful even if the following refresh fails.
                if model.projectTaskDrafts[project.id] == requestedText { model.projectTaskDrafts[project.id] = nil }
                onStarted(id, project.id)
            }
            if model.error != nil {
                notice = "Tarefa preservada. Atualize o quadro antes de tentar de novo: o agente pode ter sido criado."
            }
        }
    }
}
