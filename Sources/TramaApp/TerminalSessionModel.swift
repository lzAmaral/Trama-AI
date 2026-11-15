import SwiftUI
import TramaCore

@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published var snapshot = Data()
    @Published var hasSnapshot = false
    @Published var error: String?
    @Published var actionError: String?
    let poller = TerminalSnapshotPoller()
    private var resizeTask: Task<Void, Never>?
    private var resizeGeneration = 0
    private var requestedSize: (Int, Int)?
    private lazy var actions: TerminalActionQueue = makeActionQueue()

    private func makeActionQueue() -> TerminalActionQueue {
        let client = client
        let id = id
        let createdAtMs = createdAtMs
        let poller = poller
        let deliveries = deliveries
        return TerminalActionQueue(
            sendInput: { data in
                let sentAt = Date()
                try await client.sendInput(agentId: id, data: data, createdAtMs: createdAtMs)
                poller.requestRefresh()
                deliveries.record(sentAt)
            },
            sendResize: { rows, cols in
                try await client.resize(agentId: id, rows: rows, cols: cols, createdAtMs: createdAtMs)
                poller.requestRefresh()
            },
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
    private let deliveries: TerminalDeliveryRecorder

    init(client: OctoEngineClient, id: UInt32, createdAtMs: UInt64?, delivered: @escaping @MainActor (Date) async -> Void) {
        self.client = client; self.id = id; self.createdAtMs = createdAtMs
        self.deliveries = TerminalDeliveryRecorder(delivered: delivered)
    }

    func poll() async {
        do {
            let next = try await client.snapshot(agentId: id)
            guard let bytes = next.bytes else { throw EngineClientError.invalidResponse }
            try Task.checkCancellation()
            if bytes != snapshot { snapshot = bytes }
            if !hasSnapshot { hasSnapshot = true }
            if error != nil { error = nil }
            if resizeTask == nil { actions.reconcile(rows: next.rows, cols: next.cols) }
        } catch is CancellationError { } catch {
            let message = error.localizedDescription
            if self.error != message { self.error = message }
        }
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


/// Retained by in-flight input independently of the detail view/model.
@MainActor
private final class TerminalDeliveryRecorder {
    private let delivered: @MainActor (Date) async -> Void
    private var pending: [Date] = []
    private var worker: Task<Void, Never>?

    init(delivered: @escaping @MainActor (Date) async -> Void) { self.delivered = delivered }

    func record(_ date: Date) {
        pending.append(date)
        guard worker == nil else { return }
        // Bookkeeping keeps its order without holding the PTY input queue.
        // Confirmed deliveries finish even when their detail model has gone away.
        worker = Task {
            defer { worker = nil; pending.removeAll() }
            var next = 0
            while next < pending.count {
                let date = pending[next]
                next += 1
                await delivered(date)
            }
        }
    }
}
