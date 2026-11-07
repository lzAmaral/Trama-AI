import SwiftUI
import TramaCore

@MainActor
private final class TerminalSessionModel: ObservableObject {
    @Published var snapshot = Data()
    @Published var hasSnapshot = false
    @Published var error: String?
    @Published var actionError: String?
    private var resizeTask: Task<Void, Never>?
    private var resizeGeneration = 0
    private var requestedSize: (Int, Int)?
    private lazy var actions: TerminalActionQueue = makeActionQueue()

    private func makeActionQueue() -> TerminalActionQueue {
        let client = client
        let id = id
        let createdAtMs = createdAtMs
        let delivered = delivered
        return TerminalActionQueue(
            sendInput: { data in
                let sentAt = Date()
                try await client.sendInput(agentId: id, data: data, createdAtMs: createdAtMs)
                delivered(sentAt)
            },
            sendResize: { rows, cols in try await client.resize(agentId: id, rows: rows, cols: cols, createdAtMs: createdAtMs) },
            onFailure: { [weak self] failure in
                switch failure {
                case .input(let error): self?.actionError = "Falha ao enviar entrada. Ela não será reenviada automaticamente: \(error)"
                case .resize(let error): self?.actionError = "Não foi possível ajustar o terminal: \(error)"
                }
            })
    }
    let client: OctoEngineClient
    let id: UInt32
    let createdAtMs: UInt64?
    let delivered: @MainActor (Date) -> Void

    init(client: OctoEngineClient, id: UInt32, createdAtMs: UInt64?, delivered: @escaping @MainActor (Date) -> Void) {
        self.client = client; self.id = id; self.createdAtMs = createdAtMs; self.delivered = delivered
    }

    func poll() async {
        do {
            let next = try await client.snapshot(agentId: id)
            guard let bytes = next.bytes else { throw EngineClientError.invalidResponse }
            try Task.checkCancellation()
            if bytes != snapshot { snapshot = bytes }
            hasSnapshot = true
            error = nil
            if resizeTask == nil { actions.reconcile(rows: next.rows, cols: next.cols) }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func input(_ data: Data) {
        guard !data.isEmpty else { return }
        actionError = actions.input(data) ? nil : "Entrada não enviada. O terminal está inativo ou o limite de 24.000 bytes pendentes foi atingido. Envie trechos menores."
    }

    func resize(rows: Int, cols: Int, active: Bool = true) {
        guard rows > 0, cols > 0 else { return }
        let rows = max(2, min(rows, 100))
        let cols = max(10, min(cols, 240))
        requestedSize = (rows, cols)
        guard active else { return }
        resizeTask?.cancel()
        resizeGeneration += 1
        let generation = resizeGeneration
        resizeTask = Task {
            defer { if resizeGeneration == generation { resizeTask = nil } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                actions.resize(rows: rows, cols: cols)
            } catch is CancellationError { } catch { if resizeGeneration == generation { self.actionError = error.localizedDescription } }
        }
    }

    func suspend() {
        actions.suspend()
        resizeTask?.cancel()
        resizeTask = nil
        resizeGeneration += 1
    }

    func reconnect() {
        error = nil
        actionError = nil
        actions.resume()
        if let (rows, cols) = requestedSize { resize(rows: rows, cols: cols) }
    }
}

struct LiveAgentDetail: View {
    @ObservedObject var model: LiveWorkspaceModel
    let agentID: UInt32
    let initial: EngineAgent
    let isEmbedded: Bool
    let onClose: (() -> Void)?
    let initialTab: String
    let panelRequestID: UUID?
    @StateObject private var terminal: TerminalSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "terminal"
    @State private var reviewReloadID = UUID()
    @State private var logText = ""
    @State private var reviewedDiffAvailable = false
    @State private var loadingLogs = false
    @State private var logError: String?
    @State private var message = ""
    @State private var confirmStop = false
    @State private var confirmRemove = false
    @State private var confirmMerge = false
    @State private var notice: String?
    @State private var showsMove = false
    @State private var destinationSession = ""
    @State private var confirmArchive = false
    @State private var showsExport = false
    @State private var processTree: EngineProcessTree?
    @State private var processError: String?
    @State private var loadingProcesses = false

    init(model: LiveWorkspaceModel, agentID: UInt32, initial: EngineAgent, initialTab: String = "terminal",
         isEmbedded: Bool = false, onClose: (() -> Void)? = nil, panelRequestID: UUID? = nil) {
        self.model = model; self.agentID = agentID; self.initial = initial
        self.isEmbedded = isEmbedded; self.onClose = onClose
        self.initialTab = initialTab; self.panelRequestID = panelRequestID
        _tab = State(initialValue: initialTab)
        _terminal = StateObject(wrappedValue: TerminalSessionModel(client: model.client, id: agentID, createdAtMs: initial.createdAtMs) { [weak workflow = model.workflow] sentAt in
            if let ref = initial.deliveryReference { workflow?.inputDelivered(ref, sentAt: sentAt) }
        })
    }

    private var agent: EngineAgent { model.agents.first { $0.id == agentID && $0.deliveryReference == initial.deliveryReference } ?? initial }
    private var identityAvailable: Bool {
        initial.createdAtMs != nil && model.agents.contains { $0.id == agentID && $0.deliveryReference == initial.deliveryReference }
    }
    private var isAlive: Bool { agent.isAlive && identityAvailable }

    var body: some View {
        detailLayout
        .padding(isEmbedded ? 8 : 20)
        .frame(minWidth: isEmbedded ? nil : 760, idealWidth: isEmbedded ? nil : 960,
               maxWidth: .infinity, minHeight: isEmbedded ? nil : 600,
               idealHeight: isEmbedded ? nil : 700, maxHeight: .infinity)
        .font(TerminalTheme.mono(12))
        .foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .onAppear {
            terminal.reconnect()
            if let ref = agent.deliveryReference { model.workflow.opened(ref, panel: tab) }
        }
        .onDisappear { terminal.suspend() }
        .onChange(of: panelRequestID) { _, _ in tab = initialTab }
        .onChange(of: identityAvailable) { _, available in
            if !available {
                terminal.suspend(); reviewedDiffAvailable = false
                confirmStop = false; confirmRemove = false; confirmMerge = false; confirmArchive = false
                showsMove = false; showsExport = false
            }
        }
        .task {
            while !Task.isCancelled {
                if isAlive && tab == "terminal" { await terminal.poll() }
                do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
            }
        }
        .task(id: tab) {
            if let ref = agent.deliveryReference { model.workflow.opened(ref, panel: tab) }
            if tab == "logs" { await loadLogs() }
            if tab == "processes" { await loadProcesses() }
        }
        .sheet(isPresented: $showsMove) { movePanel }
        .sheet(isPresented: $showsExport) { LogExportView(client: model.client, agentID: agentID, name: agent.name) }
        .alert("Arquivar este worktree?", isPresented: $confirmArchive) {
            Button("Cancelar", role: .cancel) { }
            Button("Arquivar") {
                guard identityAvailable, agent.state == "exited", agent.archived != true else { return }
                Task {
                    await model.perform {
                        guard identityAvailable else { return }
                        let result = try await model.client.archiveWorktree(agentId: agentID, confirmed: true, createdAtMs: initial.createdAtMs)
                        notice = "Worktree arquivado. Pasta e branch preservadas em \(result.path)."
                    }
                }
            }
        } message: {
            Text("A pasta \(agent.cwd), a branch \(agent.branch ?? "") e todas as alterações serão preservadas no lugar. Arquivar oculta o agente do quadro padrão e bloqueia retomada e merge; não libera espaço em disco.")
        }
        .onChange(of: agent.state) { old, new in
            reviewedDiffAvailable = false
            if !isAlive { terminal.suspend() }
            else if ["lost", "exited"].contains(old) { terminal.reconnect() }
        }
        .alert("Encerrar esta sessão?", isPresented: $confirmStop) {
            Button("Cancelar", role: .cancel) { }
            Button("Encerrar", role: .destructive) {
                guard identityAvailable else { return }
                Task { await model.perform {
                    guard identityAvailable else { return }
                    try await model.client.stop(agentId: agentID, createdAtMs: initial.createdAtMs)
                } }
            }
        } message: { Text("O processo de \(agent.name) será encerrado. Os arquivos já alterados permanecem no projeto ou worktree.") }
        .alert("Remover registro e histórico?", isPresented: $confirmRemove) {
            Button("Cancelar", role: .cancel) { }
            Button("Remover", role: .destructive) {
                guard identityAvailable, agent.state == "exited", agent.branch == nil else { return }
                Task {
                    await model.perform {
                        guard identityAvailable else { return }
                        try await model.client.remove(agentId: agentID, confirmed: true, createdAtMs: initial.createdAtMs)
                        close()
                    }
                }
            }
        } message: {
            Text("O registro de \(agent.name) e seu histórico local serão excluídos permanentemente. Os arquivos do projeto serão preservados. Esta ação não pode ser desfeita.")
        }
        .alert("Integrar alterações ao projeto?", isPresented: $confirmMerge) {
            Button("Cancelar", role: .cancel) { }
            Button("Integrar") {
                guard identityAvailable, agent.state == "exited", agent.branch != nil, agent.archived != true, reviewedDiffAvailable else { return }
                Task { await model.perform {
                    guard identityAvailable else { return }
                    notice = try await model.client.merge(agentId: agentID, message: message, createdAtMs: initial.createdAtMs)
                    await loadDiff()
                } }
            }
        } message: { Text("Origem: \(agent.branch ?? "")\nProjeto: \(agent.project)\nRevise o diff. Esta ação cria commits e integra alterações ao projeto.") }
    }

    @ViewBuilder private var detailLayout: some View {
        if isEmbedded {
            GeometryReader { geometry in
                if tab == "terminal" {
                    embeddedTerminalContent(height: geometry.size.height)
                } else {
                    detailContent
                }
            }
        } else {
            detailContent
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: isEmbedded ? 6 : 12) {
            detailHeader
            if !isEmbedded {
                Text("\(agent.kind) · \(agent.session) · \(agent.cwd)")
                    .foregroundStyle(TerminalTheme.secondary).lineLimit(2).textSelection(.enabled)
            }
            panelPicker
            if !isEmbedded {
                HStack {
                    agentOptions
                    Text(agent.session).foregroundStyle(TerminalTheme.secondary).lineLimit(1)
                        .help("Sessão: \(agent.session)")
                    if agent.archived == true { Text("Worktree arquivado").foregroundStyle(TerminalTheme.secondary) }
                    Spacer()
                    resumeAction
                    Button("Encerrar", role: .destructive) { confirmStop = true }.disabled(!isAlive || model.busy)
                }.disabled(!identityAvailable)
            }
            if tab == "terminal" {
                terminalView
                    .frame(minHeight: isEmbedded ? 64 : 240, maxHeight: .infinity)
                terminalMessages
                promptComposer
            } else if tab == "diff" {
                DeliveryReviewView(client: model.client, agent: agent, workflow: model.workflow) { snapshot in
                    reviewedDiffAvailable = snapshot?.text.isEmpty == false
                }.id(reviewReloadID)
                HStack {
                    if agent.branch != nil && agent.archived != true {
                        TextField("Mensagem do merge", text: $message).textFieldStyle(.roundedBorder)
                        Button("Revisar merge…") { confirmMerge = true }
                            .disabled(model.busy || !identityAvailable || !reviewedDiffAvailable || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.state != "exited")
                    }
                }
                if agent.branch != nil {
                    Text(agent.archived == true ? "Worktree arquivado: pasta e alterações preservadas; integração indisponível." : "Encerre o agente e revise o diff antes de integrar o worktree ao projeto.")
                        .foregroundStyle(TerminalTheme.secondary)
                }
            } else if tab == "pr" {
                DeliveryPullRequestView(client: model.client, agent: agent, workflow: model.workflow)
            } else if tab == "logs" {
                if loadingLogs { ProgressView("Lendo histórico…") }
                if let logError { Text(logError).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
                HStack {
                    Button(loadingLogs ? "Lendo histórico…" : "Atualizar histórico") { Task { await loadLogs() } }.disabled(loadingLogs)
                    Button("Preparar exportação…") { showsExport = true }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(logText.isEmpty ? (loadingLogs ? "" : (logError == nil ? "Nenhum histórico disponível." : "")) : logText)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: isEmbedded ? 80 : 360, maxHeight: .infinity)
            } else if tab == "processes" {
                processPanel
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let nested = agent.nested {
                            Text("Processo aninhado: \(nested.kind) · PID \(nested.pid)")
                                .foregroundStyle(TerminalTheme.accent)
                        }
                        Text(agent.task.isEmpty ? "Terminal interativo sem tarefa inicial." : agent.task)
                        Text(agent.activity).foregroundStyle(TerminalTheme.secondary)
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: isEmbedded ? 80 : 360, maxHeight: .infinity)
            }
            detailNotices
        }
    }

    // Keep the native terminal outside the scroll region at every window size.
    // Bound only the composer/messages area, so additional errors cannot push
    // its controls below the viewport and resizing does not replace the terminal.
    private func embeddedTerminalContent(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailHeader
            panelPicker
            terminalView.frame(minHeight: 48, maxHeight: .infinity)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    promptComposer
                    terminalMessages
                    detailNotices
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
            }.frame(height: min(180, max(0, height - 116)))
                .accessibilityLabel("Instrução e mensagens de \(agent.name)")
        }
    }

    private var detailHeader: some View {
        HStack {
            Text("\(agent.name) #\(agent.id)").font(TerminalTheme.mono(isEmbedded ? 15 : 18, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Text(liveStateTitle(agent.state)).foregroundStyle(liveStateColor(agent.state))
            Spacer()
            if isEmbedded {
                agentOptions
                resumeAction
            }
            Button("Fechar", action: close).keyboardShortcut("w")
                .help("Fechar detalhes (⌘W). Escape permanece disponível para o terminal.")
        }
    }

    private var panelPicker: some View {
        Picker("Painel", selection: $tab) {
            Text("Terminal").tag("terminal")
            Text("Alterações").tag("diff")
            Text("PR/CI").tag("pr")
            Text("Histórico").tag("logs")
            Text("Tarefa").tag("task")
            Text("Processos").tag("processes")
        }.pickerStyle(.segmented)
    }

    private var terminalView: some View {
        NativeTerminalView(snapshot: terminal.snapshot, name: agent.name, isInteractive: isAlive && !model.busy,
                           onInput: { if isAlive && !model.busy { terminal.input($0) } },
                           onResize: { rows, cols in terminal.resize(rows: rows, cols: cols, active: isAlive) })
            .id(initial.deliveryReference)
            .overlay(Rectangle().stroke(TerminalTheme.border))
    }

    @ViewBuilder private var terminalMessages: some View {
        if isAlive && !terminal.hasSnapshot && terminal.error == nil {
            ProgressView("Carregando terminal…").controlSize(.small)
        }
        if !isAlive {
            Text(terminal.hasSnapshot
                 ? "Sessão \(liveStateTitle(agent.state).lowercased()). Última tela capturada nesta janela."
                 : "Sessão \(liveStateTitle(agent.state).lowercased()). Consulte o histórico para ver a saída persistida.")
                .foregroundStyle(TerminalTheme.secondary)
        }
        if let error = terminal.actionError ?? terminal.error, isAlive {
            Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(2)
        }
    }

    private var promptComposer: some View {
        AgentPromptComposer(model: model, agent: agent, identityAvailable: identityAvailable)
            .id(initial.deliveryReference)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var detailNotices: some View {
        if model.busy { ProgressView("Aplicando operação…").controlSize(.small) }
        if !identityAvailable {
            Text("Este registro não está disponível no quadro atual. Reabra os detalhes após atualizar; entrada desativada.")
                .foregroundStyle(TerminalTheme.warning)
        }
        if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).lineLimit(3) }
        if let error = model.error { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(3) }
    }

    private var agentOptions: some View {
        Menu("Opções") {
            Text("Sessão: \(agent.session)")
            Button("Mover para sessão…") { destinationSession = agent.session; showsMove = true }
                .disabled(model.busy || agent.state != "exited")
            if agent.branch != nil && agent.archived != true {
                Button("Arquivar worktree…") { confirmArchive = true }
                    .disabled(model.busy || agent.state != "exited")
            }
            if agent.archived == true { Text("Worktree arquivado") }
            if agent.state == "exited" && agent.branch == nil {
                Button("Remover registro…", role: .destructive) { confirmRemove = true }.disabled(model.busy)
            }
            if isEmbedded {
                Divider()
                Button("Encerrar", role: .destructive) { confirmStop = true }.disabled(!isAlive || model.busy)
            }
        }.fixedSize().disabled(!identityAvailable)
    }

    @ViewBuilder private var resumeAction: some View {
        if agent.state == "lost" && agent.archived != true {
            Button("Retomar") {
                guard identityAvailable else { return }
                Task { await model.perform {
                    guard identityAvailable else { return }
                    try await model.client.resume(agentId: agentID, createdAtMs: initial.createdAtMs)
                } }
            }.disabled(model.busy || !identityAvailable)
        }
    }

    private func close() {
        terminal.suspend()
        if isEmbedded { onClose?() } else { dismiss() }
    }

    private var movePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mover \(agent.name) para sessão").font(TerminalTheme.mono(18, weight: .medium)).accessibilityAddTraits(.isHeader)
            Picker("Sessão de destino", selection: $destinationSession) {
                ForEach(Array(Set(model.sessions + [destinationSession])).sorted(), id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy)
            Text("Os arquivos permanecem no mesmo lugar. Apenas o agrupamento da sessão muda; o agente precisa estar encerrado.")
                .foregroundStyle(TerminalTheme.secondary)
            if let error = model.error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            HStack {
                Button("Cancelar") { showsMove = false }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Mover") {
                    guard identityAvailable, agent.state == "exited" else { return }
                    let destination = destinationSession
                    Task {
                        await model.perform {
                            guard identityAvailable else { return }
                            try await model.client.moveAgent(agentId: agentID, to: destination, createdAtMs: initial.createdAtMs)
                            showsMove = false
                        }
                    }
                }.disabled(model.busy || agent.state != "exited" || destinationSession.isEmpty || destinationSession == agent.session)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
            .font(TerminalTheme.mono(13)).background(TerminalTheme.background)
            .foregroundStyle(TerminalTheme.primary).preferredColorScheme(.dark)
            .interactiveDismissDisabled(model.busy)
    }

    private var processPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Atualizar processos") { Task { await loadProcesses() } }.disabled(loadingProcesses)
                if loadingProcesses { ProgressView("Lendo processos locais…").controlSize(.small) }
            }
            if let processError { Text(processError).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Processos observados localmente · esta consulta não representa toda a árvore de agentes do provedor.")
                        .foregroundStyle(TerminalTheme.secondary)
                    if let tree = processTree {
                        Text("Observado em \(Date(timeIntervalSince1970: Double(tree.observedAtMs) / 1000).formatted())")
                        if tree.nodes.isEmpty { Text("Nenhum processo local disponível para este agente.") }
                        ForEach(tree.nodes, id: \.pid) { node in
                            Text("PID \(node.pid) · \(node.name)\(node.kind.map { " · " + $0 } ?? "")\(node.parentPid.map { " · pai " + String($0) } ?? "")")
                        }
                        ForEach(Array(tree.limitations.enumerated()), id: \.offset) { _, limitation in
                            Text(limitation).foregroundStyle(TerminalTheme.warning)
                        }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minHeight: isEmbedded ? 80 : 360, maxHeight: .infinity)
    }

    @MainActor private func loadProcesses() async {
        guard !loadingProcesses else { return }
        loadingProcesses = true; processError = nil
        defer { loadingProcesses = false }
        do {
            let result = try await model.client.processTree(agentId: agentID)
            try Task.checkCancellation()
            processTree = result
        } catch is CancellationError { } catch { processError = error.localizedDescription }
    }

    @MainActor private func loadLogs() async {
        guard !loadingLogs else { return }
        loadingLogs = true
        logError = nil
        defer { loadingLogs = false }
        do {
            let result = try await model.client.logs(agentId: agentID)
            try Task.checkCancellation()
            logText = (result.truncated ? "[último trecho do histórico]\n" : "") + result.text
        } catch is CancellationError { } catch { logError = "Não foi possível ler o histórico: \(error.localizedDescription)" }
    }

    @MainActor private func loadDiff() async {
        reviewedDiffAvailable = false
        reviewReloadID = UUID()
    }
}
