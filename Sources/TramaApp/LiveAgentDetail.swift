import SwiftUI
import TramaCore

@MainActor
private final class TerminalSessionModel: ObservableObject {
    @Published var snapshot = Data()
    @Published var error: String?
    @Published var actionError: String?
    private var pendingInput = Data()
    private var sending = false
    private var resizeTask: Task<Void, Never>?
    private var resizeGeneration = 0
    private var lastSize: (Int, Int)?
    private var requestedSize: (Int, Int)?
    let client: OctoEngineClient
    let id: UInt32

    init(client: OctoEngineClient, id: UInt32) { self.client = client; self.id = id }

    func poll() async {
        do {
            let next = try await client.snapshot(agentId: id)
            guard let bytes = next.bytes else { throw EngineClientError.invalidResponse }
            try Task.checkCancellation()
            if bytes != snapshot { snapshot = bytes }
            error = nil
            // A failed resize or a restarted holder must converge even when the view
            // geometry does not change and AppKit emits no further resize callback.
            if let (rows, cols) = requestedSize, resizeTask == nil,
               rows != next.rows || cols != next.cols {
                lastSize = nil
                resize(rows: rows, cols: cols)
            }
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    func input(_ data: Data) {
        guard pendingInput.count + data.count <= 24_000 else {
            actionError = "Entrada muito longa. Envie trechos menores."
            return
        }
        actionError = nil
        pendingInput.append(data)
        guard !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            while !pendingInput.isEmpty {
                let bytes = pendingInput
                pendingInput.removeAll()
                do { try await client.sendInput(agentId: id, data: bytes) }
                catch { self.actionError = error.localizedDescription; pendingInput.removeAll(); break }
            }
        }
    }

    func resize(rows: Int, cols: Int, active: Bool = true) {
        guard rows > 0, cols > 0 else { return }
        let rows = min(rows, 100)
        let cols = min(cols, 240)
        requestedSize = (rows, cols)
        guard active else { return }
        if let lastSize, lastSize == (rows, cols) { return }
        resizeTask?.cancel()
        resizeGeneration += 1
        let generation = resizeGeneration
        resizeTask = Task {
            defer { if resizeGeneration == generation { resizeTask = nil } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await client.resize(agentId: id, rows: rows, cols: cols)
                lastSize = (rows, cols)
            } catch is CancellationError { } catch { if resizeGeneration == generation { self.actionError = error.localizedDescription; lastSize = nil } }
        }
    }

    func reconnect() {
        lastSize = nil
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
    @State private var message = ""
    @State private var confirmStop = false
    @State private var confirmRemove = false
    @State private var confirmMerge = false
    @State private var notice: String?

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
                Text(liveStateTitle(agent.state)).foregroundStyle(liveStateColor(agent.state))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(agent.kind) · \(agent.session) · \(agent.cwd)")
                .foregroundStyle(TerminalTheme.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                Picker("Painel", selection: $tab) {
                    Text("Terminal").tag("terminal")
                    Text("Alterações").tag("diff")
                    Text("Histórico").tag("logs")
                    Text("Tarefa").tag("task")
                }.pickerStyle(.segmented).frame(width: 400)
                Spacer()
                if agent.state == "lost" {
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
                NativeTerminalView(snapshot: terminal.snapshot,
                                   onInput: { if isAlive { terminal.input($0) } },
                                   onResize: { rows, cols in terminal.resize(rows: rows, cols: cols, active: isAlive) })
                    .id(agentID)
                    .frame(minHeight: 360)
                    .overlay(Rectangle().stroke(TerminalTheme.border))
                if !isAlive { Text("Sessão \(liveStateTitle(agent.state).lowercased()). Última tela disponível nesta janela.").foregroundStyle(TerminalTheme.secondary) }
                if let error = terminal.actionError ?? terminal.error, isAlive { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(3) }
            } else if tab == "diff" {
                if loadingDiff { ProgressView("Lendo alterações…") }
                ScrollView([.horizontal, .vertical]) {
                    Text(diffText.isEmpty ? "Nenhuma alteração disponível." : diffText)
                        .font(TerminalTheme.mono(12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(minHeight: 320)
                HStack {
                    Button("Atualizar diff") { Task { await loadDiff() } }.disabled(loadingDiff)
                    if agent.branch != nil {
                        TextField("Mensagem do merge", text: $message).textFieldStyle(.roundedBorder)
                        Button("Revisar merge…") { confirmMerge = true }
                            .disabled(model.busy || loadingDiff || !reviewedDiffAvailable || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.state != "exited")
                    }
                }
                if agent.branch != nil { Text("Encerre o agente e revise o diff antes de integrar o worktree ao projeto.").foregroundStyle(TerminalTheme.secondary) }
            } else if tab == "logs" {
                Button(loadingLogs ? "Lendo histórico…" : "Atualizar histórico") { Task { await loadLogs() } }.disabled(loadingLogs)
                ScrollView([.horizontal, .vertical]) {
                    Text(logText.isEmpty ? "Nenhum histórico disponível." : logText)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 360)
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
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).lineLimit(3) }
            if let error = model.error { Text(error).foregroundStyle(TerminalTheme.warning).lineLimit(3) }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 960, minHeight: 600, idealHeight: 700)
        .font(TerminalTheme.mono(12))
        .foregroundStyle(TerminalTheme.primary).background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                if isAlive && tab == "terminal" { await terminal.poll() }
                do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
            }
        }
        .task(id: tab) { if tab == "diff" { await loadDiff() }; if tab == "logs" { await loadLogs() } }
        .onChange(of: agent.state) { old, new in
            if ["lost", "exited"].contains(old) && !["lost", "exited"].contains(new) { terminal.reconnect() }
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
                Task { await model.perform { notice = try await model.client.merge(agentId: agentID, message: message); await loadDiff() } }
            }
        } message: { Text("Origem: \(agent.branch ?? "")\nProjeto: \(agent.project)\nRevise o diff. Esta ação cria commits e integra alterações ao projeto.") }
    }

    @MainActor private func loadLogs() async {
        guard !loadingLogs else { return }
        loadingLogs = true
        defer { loadingLogs = false }
        do {
            let result = try await model.client.logs(agentId: agentID)
            logText = (result.truncated ? "[último trecho do histórico]\n" : "") + result.text
        } catch is CancellationError { } catch { logText = error.localizedDescription }
    }

    @MainActor private func loadDiff() async {
        guard !loadingDiff else { return }
        reviewedDiffAvailable = false
        loadingDiff = true
        defer { loadingDiff = false }
        do {
            diffText = try await model.client.diff(agentId: agentID)
            try Task.checkCancellation()
            reviewedDiffAvailable = true
        } catch is CancellationError { } catch { diffText = error.localizedDescription }
    }
}
