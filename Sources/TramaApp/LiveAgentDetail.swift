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
        return TerminalActionQueue(
            sendInput: { data in try await client.sendInput(agentId: id, data: data) },
            sendResize: { rows, cols in try await client.resize(agentId: id, rows: rows, cols: cols) },
            onFailure: { [weak self] failure in
                switch failure {
                case .input(let error): self?.actionError = "Falha ao enviar entrada. Ela não será reenviada automaticamente: \(error)"
                case .resize(let error): self?.actionError = "Não foi possível ajustar o terminal: \(error)"
                }
            })
    }
    let client: OctoEngineClient
    let id: UInt32

    init(client: OctoEngineClient, id: UInt32) { self.client = client; self.id = id }

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
    @StateObject private var terminal: TerminalSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "terminal"
    @State private var diffText = ""
    @State private var logText = ""
    @State private var loadingDiff = false
    @State private var reviewedDiffAvailable = false
    @State private var loadingLogs = false
    @State private var diffError: String?
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

    init(model: LiveWorkspaceModel, agentID: UInt32, initial: EngineAgent) {
        self.model = model; self.agentID = agentID; self.initial = initial
        _terminal = StateObject(wrappedValue: TerminalSessionModel(client: model.client, id: agentID))
    }

    private var agent: EngineAgent { model.agents.first { $0.id == agentID } ?? initial }
    private var isAlive: Bool { agent.isAlive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(agent.name) #\(agent.id)").font(TerminalTheme.mono(18, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Text(liveStateTitle(agent.state)).foregroundStyle(liveStateColor(agent.state))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut("w")
                    .help("Fechar detalhes (⌘W). Escape permanece disponível para o terminal.")
            }
            Text("\(agent.kind) · \(agent.session) · \(agent.cwd)")
                .foregroundStyle(TerminalTheme.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                Picker("Painel", selection: $tab) {
                    Text("Terminal").tag("terminal")
                    Text("Alterações").tag("diff")
                    Text("Histórico").tag("logs")
                    Text("Tarefa").tag("task")
                    Text("Processos").tag("processes")
                }.pickerStyle(.segmented).frame(minWidth: 400)
            }
            HStack {
                Button("Mover para sessão…") { destinationSession = agent.session; showsMove = true }.disabled(model.busy || agent.state != "exited")
                    .help("Encerre o agente antes de mudar sua sessão")
                if agent.branch != nil && agent.archived != true {
                    Button("Arquivar worktree…") { confirmArchive = true }.disabled(model.busy || agent.state != "exited")
                }
                if agent.archived == true { Text("Worktree arquivado").foregroundStyle(TerminalTheme.secondary) }
                Spacer()
                if agent.state == "lost" && agent.archived != true {
                    Button("Retomar") { Task { await model.perform { try await model.client.resume(agentId: agentID) } } }
                        .disabled(model.busy)
                }
                if agent.state == "exited" && agent.branch == nil {
                    Button("Remover registro…", role: .destructive) { confirmRemove = true }
                        .disabled(model.busy)
                }
                Button("Encerrar", role: .destructive) { confirmStop = true }.disabled(!isAlive || model.busy)
            }
            if tab == "terminal" {
                NativeTerminalView(snapshot: terminal.snapshot, name: agent.name, isInteractive: isAlive && !model.busy,
                                   onInput: { if isAlive && !model.busy { terminal.input($0) } },
                                   onResize: { rows, cols in terminal.resize(rows: rows, cols: cols, active: isAlive) })
                    .id(agentID)
                    .frame(minHeight: 360)
                    .overlay(Rectangle().stroke(TerminalTheme.border))
                if isAlive && !terminal.hasSnapshot && terminal.error == nil { ProgressView("Carregando terminal…") }
                if !isAlive {
                    Text(terminal.hasSnapshot
                         ? "Sessão \(liveStateTitle(agent.state).lowercased()). Última tela capturada nesta janela."
                         : "Sessão \(liveStateTitle(agent.state).lowercased()). Consulte o histórico para ver a saída persistida.")
                        .foregroundStyle(TerminalTheme.secondary)
                }
                if let error = terminal.actionError ?? terminal.error, isAlive { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(3) }
            } else if tab == "diff" {
                if loadingDiff { ProgressView("Lendo alterações…") }
                ScrollView([.horizontal, .vertical]) {
                    Text(diffText.isEmpty ? (loadingDiff ? "" : (diffError == nil ? "Nenhuma alteração disponível." : "")) : diffText)
                        .font(TerminalTheme.mono(12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(minHeight: 320)
                if let diffError { Text(diffError).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
                HStack {
                    Button("Atualizar diff") { Task { await loadDiff() } }.disabled(loadingDiff)
                    if agent.branch != nil && agent.archived != true {
                        TextField("Mensagem do merge", text: $message).textFieldStyle(.roundedBorder)
                        Button("Revisar merge…") { confirmMerge = true }
                            .disabled(model.busy || loadingDiff || !reviewedDiffAvailable || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.state != "exited")
                    }
                }
                if agent.branch != nil {
                    Text(agent.archived == true ? "Worktree arquivado: pasta e alterações preservadas; integração indisponível." : "Encerre o agente e revise o diff antes de integrar o worktree ao projeto.")
                        .foregroundStyle(TerminalTheme.secondary)
                }
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
                }.frame(minHeight: 360)
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
                }.frame(minHeight: 360)
            }
            if model.busy { ProgressView("Aplicando operação…").controlSize(.small) }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).lineLimit(3) }
            if let error = model.error { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(3) }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 960, minHeight: 600, idealHeight: 700)
        .font(TerminalTheme.mono(12))
        .foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .onAppear { terminal.reconnect() }
        .onDisappear { terminal.suspend() }
        .task {
            while !Task.isCancelled {
                if isAlive && tab == "terminal" { await terminal.poll() }
                do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
            }
        }
        .task(id: tab) {
            if tab == "diff" { await loadDiff() }
            if tab == "logs" { await loadLogs() }
            if tab == "processes" { await loadProcesses() }
        }
        .sheet(isPresented: $showsMove) { movePanel }
        .sheet(isPresented: $showsExport) { LogExportView(client: model.client, agentID: agentID, name: agent.name) }
        .alert("Arquivar este worktree?", isPresented: $confirmArchive) {
            Button("Cancelar", role: .cancel) { }
            Button("Arquivar") {
                guard agent.state == "exited", agent.archived != true else { return }
                Task {
                    await model.perform {
                        let result = try await model.client.archiveWorktree(agentId: agentID, confirmed: true)
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
            Button("Encerrar", role: .destructive) { Task { await model.perform { try await model.client.stop(agentId: agentID) } } }
        } message: { Text("O processo de \(agent.name) será encerrado. Os arquivos já alterados permanecem no projeto ou worktree.") }
        .alert("Remover registro e histórico?", isPresented: $confirmRemove) {
            Button("Cancelar", role: .cancel) { }
            Button("Remover", role: .destructive) {
                guard agent.state == "exited", agent.branch == nil else { return }
                Task {
                    await model.perform {
                        try await model.client.remove(agentId: agentID, confirmed: true)
                        dismiss()
                    }
                }
            }
        } message: {
            Text("O registro de \(agent.name) e seu histórico local serão excluídos permanentemente. Os arquivos do projeto serão preservados. Esta ação não pode ser desfeita.")
        }
        .alert("Integrar alterações ao projeto?", isPresented: $confirmMerge) {
            Button("Cancelar", role: .cancel) { }
            Button("Integrar") {
                guard agent.state == "exited", agent.branch != nil, agent.archived != true, reviewedDiffAvailable else { return }
                Task { await model.perform { notice = try await model.client.merge(agentId: agentID, message: message); await loadDiff() } }
            }
        } message: { Text("Origem: \(agent.branch ?? "")\nProjeto: \(agent.project)\nRevise o diff. Esta ação cria commits e integra alterações ao projeto.") }
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
                    guard agent.state == "exited" else { return }
                    let destination = destinationSession
                    Task {
                        await model.perform {
                            try await model.client.moveAgent(agentId: agentID, to: destination)
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
        }.frame(minHeight: 360)
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
        guard !loadingDiff else { return }
        reviewedDiffAvailable = false
        loadingDiff = true
        diffError = nil
        defer { loadingDiff = false }
        do {
            let state = agent.state
            let result = try await model.client.diff(agentId: agentID)
            try Task.checkCancellation()
            diffText = result
            reviewedDiffAvailable = state == agent.state
        } catch is CancellationError { } catch { diffError = "Não foi possível ler as alterações: \(error.localizedDescription)" }
    }
}
