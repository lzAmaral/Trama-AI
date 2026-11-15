import SwiftUI
import TramaCore

/// Native adaptation of Octo's composer layout (MIT), commit 1dc08a44bc7698dbabfca37730de7df572d6091f.
/// Source: lucasmarujo/octo desktop/ui/index.html and styles.css. Provider approvals stay in the terminal.
struct ProjectTaskComposer: View {
    @ObservedObject var model: LiveWorkspaceModel
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    let preferredSession: String
    let onAddProject: () -> Void
    let onStarted: (DeliveryAgentReference, UUID) -> Void
    @State private var kind = ""
    @State private var name = ""
    @State private var isolate = false
    @State private var creating = false
    @State private var showsOptions = false
    @State private var showsFolderPicker = false
    @State private var notice: String?
    @State private var skills: [EngineSkill] = []
    @State private var loadingSkills = false
    @State private var skillError: String?
    @State private var taskFocused = false

    init(model: LiveWorkspaceModel, projects: [Project], selectedProjectID: Binding<UUID?>,
         preferredSession: String, onAddProject: @escaping () -> Void,
         onStarted: @escaping (DeliveryAgentReference, UUID) -> Void) {
        self.model = model
        self.projects = projects
        _selectedProjectID = selectedProjectID
        self.preferredSession = preferredSession
        self.onAddProject = onAddProject
        self.onStarted = onStarted
    }

    private struct SkillRequest: Hashable {
        let projectID: UUID
        let path: String
        let kind: String
    }

    private var project: Project? { projects.first { $0.id == selectedProjectID } }
    private var providers: [EngineProvider] { model.providers.filter(\.installed) }
    private var isBusy: Bool { creating || model.busy }
    private var sessionSelection: EngineSessionSelection {
        EngineSessionSelection(sessions: model.sessions, preferredSession: preferredSession)
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
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }
    private var skillRequest: SkillRequest? {
        let text = draft.wrappedValue
        guard !isBusy, kind != "terminal", providers.contains(where: { $0.id == kind }),
              text.hasPrefix("/"), !text.contains(where: \.isWhitespace), let project else { return nil }
        return SkillRequest(projectID: project.id, path: project.path, kind: kind)
    }
    private var matchingSkills: [EngineSkill] {
        let query = String(draft.wrappedValue.dropFirst())
        return skills.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.invocation.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                composerLine
                composerOptions
                if messageHeight > 0 {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) { messages }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: messageHeight)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
            .background(TerminalTheme.surface, in: Rectangle())
            .overlay(Rectangle().stroke(taskFocused ? TerminalTheme.secondary.opacity(0.4) : TerminalTheme.border))
        }
        .overlay(alignment: .top) {
            if skillRequest != nil {
                skillPalette.frame(height: paletteHeight).offset(y: -paletteHeight - 8)
            }
        }
        .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.primary)
        .onAppear { selectProvider(); taskFocused = project != nil }
        .onChange(of: model.providers) { _, _ in selectProvider() }
        .onChange(of: project?.id) { _, id in notice = nil; taskFocused = id != nil }
        .task(id: skillRequest) { await loadSkills() }
    }

    private var composerLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(TerminalTheme.accent).frame(width: 2, height: 20)
                .padding(.top, 6).accessibilityHidden(true)
            ZStack(alignment: .topLeading) {
                ComposerTextEditor(text: draft, isFocused: $taskFocused,
                                   isEditable: project != nil && !isBusy,
                                   accessibilityLabel: "Tarefa para um novo agente",
                                   accessibilityIdentifier: "task-composer-editor")
                    .id(project?.id)
                if draft.wrappedValue.isEmpty {
                    Text(project == nil ? "Escolha a pasta de destino…" : "Escreva uma tarefa…")
                        .font(TerminalTheme.ui(14)).foregroundStyle(TerminalTheme.muted)
                        .padding(.top, 6).allowsHitTesting(false)
                }
            }.frame(height: 52).frame(maxWidth: .infinity)
        }
    }

    private var composerOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    providerMenu.frame(width: 136)
                    folderMenu.frame(minWidth: 220, maxWidth: .infinity)
                    taskActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    folderMenu.frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        providerMenu.frame(maxWidth: 180)
                        Spacer(minLength: 8)
                        taskActions
                    }
                }
            }
            HStack(spacing: 8) {
                Label(sessionSelection.selectedSession ?? "Sem sessão", systemImage: "rectangle.stack")
                    .font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("Sessão de destino: \(sessionSelection.selectedSession ?? "nenhuma")")
                    .help("Sessão de destino: \(sessionSelection.selectedSession ?? "nenhuma")")
                Spacer(minLength: 0)
                if kind != "terminal" {
                    Text("/ skills").font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
                        .fixedSize().help("Digite / para consultar as skills reais do projeto e provedor")
                }
            }
        }
    }

    private var taskActions: some View {
        HStack(spacing: 8) {
            Button { showsOptions = true } label: {
                Image(systemName: isolate ? "arrow.triangle.branch" : "line.3.horizontal")
                    .frame(width: 14)
            }
            .buttonStyle(WorkspaceChipStyle())
            .foregroundStyle(isolate ? TerminalTheme.accent : TerminalTheme.secondary)
            .accessibilityLabel("Opções da tarefa").accessibilityIdentifier("task-composer-options")
            .help("Nome, sessão e isolamento em worktree")
            .popover(isPresented: $showsOptions) { advancedOptions }
            if creating { ProgressView().controlSize(.small) }
            Button(action: start) {
                HStack(spacing: 8) {
                    Text("Iniciar")
                    Text("⌘↵").font(TerminalTheme.mono(11))
                }
            }
            .buttonStyle(NativeActionButtonStyle(primary: true))
            .accessibilityLabel("Iniciar agente").accessibilityIdentifier("task-composer-start")
            .keyboardShortcut(.return, modifiers: .command).disabled(!valid)
        }.fixedSize()
    }

    private var providerMenu: some View {
        Menu {
            ForEach(providers) { provider in
                Button { kind = provider.id } label: {
                    if provider.id == kind { Label(providerName(provider.id), systemImage: "checkmark") }
                    else { Text(providerName(provider.id)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(kind.isEmpty ? "Provedor" : providerName(kind))
                    .font(TerminalTheme.mono(12, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundStyle(TerminalTheme.providerColor(kind))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(TerminalTheme.providerColor(kind))
        .buttonStyle(WorkspaceChipStyle())
        .accessibilityLabel("Provedor do novo agente: \(providerName(kind))")
        .accessibilityIdentifier("task-composer-provider").help(providerName(kind))
        .disabled(isBusy || providers.isEmpty)
    }

    private var folderMenu: some View {
        Button { showsFolderPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12)).fixedSize()
                Text(project.map { shortPath($0.path) } ?? "Escolher pasta")
                    .font(TerminalTheme.mono(12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).fixedSize()
            }.foregroundStyle(project == nil ? TerminalTheme.secondary : TerminalTheme.accent)
        }
        .buttonStyle(WorkspaceChipStyle()).frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityLabel(project.map { "Pasta de destino: \($0.name), \($0.path)" } ?? "Escolher pasta de destino")
        .accessibilityIdentifier("task-composer-folder")
        .help(project?.path ?? "Escolha explicitamente a pasta onde o agente será iniciado")
        .disabled(isBusy)
        .popover(isPresented: $showsFolderPicker) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pasta de destino").font(TerminalTheme.ui(14, weight: .medium))
                if !projects.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(projects) { item in
                                Button {
                                    selectedProjectID = item.id
                                    showsFolderPicker = false
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: item.id == selectedProjectID ? "checkmark" : "folder")
                                            .frame(width: 16)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name).font(TerminalTheme.ui(12, weight: .medium))
                                            Text(shortPath(item.path)).font(TerminalTheme.mono(10))
                                                .foregroundStyle(TerminalTheme.secondary)
                                        }.lineLimit(2).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(item.path)
                            }
                        }
                    }.frame(height: min(CGFloat(projects.count) * 64, 240))
                }
                Button("Adicionar projeto…", systemImage: "plus") {
                    showsFolderPicker = false
                    onAddProject()
                }
            }.padding(16).frame(width: 360)
        }
    }

    private var messageHeight: CGFloat {
        var height: CGFloat = 0
        if project == nil || sessionSelection.selectedSession == nil { height += 20 }
        if model.loadingProviders { height += 24 }
        if model.providerError != nil { height += 76 }
        else if providers.isEmpty && !model.loadingProviders { height += 20 }
        if notice != nil { height += 44 }
        return min(88, height)
    }

    @ViewBuilder private var messages: some View {
        if project == nil {
            Text("Escolha a pasta de destino antes de iniciar.").foregroundStyle(TerminalTheme.secondary)
        } else if sessionSelection.selectedSession == nil {
            Text("Crie uma sessão antes de iniciar o agente.").foregroundStyle(TerminalTheme.warning)
        }
        if model.loadingProviders { ProgressView("Verificando provedores…").controlSize(.small) }
        if let error = model.providerError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Falha ao detectar provedores: \(error)")
                    .lineLimit(2).truncationMode(.tail).help(error)
                Button("Verificar novamente") { Task { await model.loadProviders() } }
                    .disabled(model.loadingProviders)
            }.foregroundStyle(TerminalTheme.warning)
        } else if providers.isEmpty && !model.loadingProviders {
            Text("Nenhum provedor instalado disponível.").foregroundStyle(TerminalTheme.warning)
        }
        if let notice { Text(notice).foregroundStyle(TerminalTheme.warning).lineLimit(2) }
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Opções da tarefa").font(TerminalTheme.ui(14, weight: .medium))
                Spacer()
                Button("Concluído") { showsOptions = false }
            }
            if let project {
                Text(project.path).font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Nome do agente (opcional)", text: $name).textFieldStyle(.roundedBorder)
            Picker("Sessão", selection: Binding(
                get: { sessionSelection.selectedSession }, set: { model.selectScope(projectID: selectedProjectID, session: $0) }
            )) {
                if sessionSelection.options.isEmpty { Text("Nenhuma sessão disponível").tag(nil as String?) }
                ForEach(sessionSelection.options, id: \.self) { Text($0).tag(Optional($0)) }
            }
            Toggle("Isolar em um worktree Git", isOn: $isolate)
            Text(kind == "terminal" ? "O shell executa a tarefa como comando na pasta indicada."
                 : "O agente usa seu login do provedor. Responda às aprovações no terminal.")
                .foregroundStyle(TerminalTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(TerminalTheme.ui(12)).padding(20).frame(width: 360)
            .disabled(isBusy)
    }

    private var paletteHeight: CGFloat {
        if loadingSkills || skillError != nil || matchingSkills.isEmpty { return 52 }
        return min(CGFloat(matchingSkills.count) * 32, 128) + 8
    }

    private var skillPalette: some View {
        VStack(alignment: .leading, spacing: 4) {
            if loadingSkills { ProgressView("Lendo skills do projeto…").controlSize(.small).padding(8) }
            else if let skillError {
                Text(skillError).foregroundStyle(TerminalTheme.warning).lineLimit(3)
                    .help(skillError).padding(8)
            }
            else if matchingSkills.isEmpty { Text("Nenhuma skill encontrada").foregroundStyle(TerminalTheme.secondary).padding(8) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matchingSkills.enumerated()), id: \.offset) { _, skill in
                            Button {
                                draft.wrappedValue = skill.invocation + " "
                                taskFocused = true
                            } label: {
                                HStack(spacing: 12) {
                                    Text(skill.name).font(TerminalTheme.mono(12)).lineLimit(1)
                                        .frame(maxWidth: 180, alignment: .leading)
                                    Text(skill.description).font(TerminalTheme.ui(12))
                                        .foregroundStyle(TerminalTheme.secondary).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Inserir skill \(skill.name)")
                                .help("\(skill.name): \(skill.description)")
                        }
                    }
                }.frame(height: min(CGFloat(matchingSkills.count) * 32, 128))
            }
        }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            .background(TerminalTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(TerminalTheme.border))
    }

    @MainActor private func loadSkills() async {
        skills = []; skillError = nil
        guard let request = skillRequest else { loadingSkills = false; return }
        loadingSkills = true
        defer { if skillRequest == request { loadingSkills = false } }
        do {
            let result = try await model.client.skills(kind: request.kind, cwd: request.path)
            try Task.checkCancellation()
            guard skillRequest == request else { return }
            skills = result
        } catch is CancellationError { } catch {
            if skillRequest == request { skillError = error.localizedDescription }
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func providerName(_ id: String) -> String { id == "terminal" ? "Shell" : id }

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
