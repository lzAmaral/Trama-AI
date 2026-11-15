import Foundation
import SwiftUI
import TramaCore

/// Repository operations never suspend while holding their filesystem lock, and never run on MainActor.
private actor DeliveryWorkflowStorage {
    let repository: DeliveryWorkflowRepository

    init(repository: DeliveryWorkflowRepository) { self.repository = repository }

    func run<Value: Sendable>(_ operation: @Sendable (DeliveryWorkflowRepository) throws -> Value) -> Result<Value, Error> {
        Result { try operation(repository) }
    }
}

@MainActor
final class DeliveryWorkflowViewModel: ObservableObject {
    @Published private(set) var snapshot: DeliveryWorkflowSnapshot?
    @Published private(set) var error: String?
    let repository: DeliveryWorkflowRepository
    let notifications = DeliveryNotifications()
    private let storage: DeliveryWorkflowStorage
    private var tail: Task<Void, Never>?

    init(engineHome: URL) {
        self.repository = DeliveryWorkflowRepository(engineHome: engineHome)
        self.storage = DeliveryWorkflowStorage(repository: repository)
    }

    // Injectable storage keeps tests isolated, including clock and filesystem failures.
    init(repository: DeliveryWorkflowRepository) {
        self.repository = repository
        self.storage = DeliveryWorkflowStorage(repository: repository)
    }

    var pending: [DeliveryIntervention] {
        (snapshot?.interventions ?? []).filter(\.isPending).sorted { $0.createdAt < $1.createdAt }
    }
    var unreadCount: Int { pending.filter { $0.readAt == nil }.count }

    /// Queue the entire operation, including publication, so a slow read cannot replace a newer mutation.
    /// Once queued, local writes finish even if their initiating view disappears.
    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable (DeliveryWorkflowRepository) throws -> Value,
        publish: @escaping @MainActor (Result<Value, Error>) -> Void
    ) async -> Result<Value, Error> {
        let previous = tail
        let storage = storage
        let task = Task { @MainActor in
            await previous?.value
            let result = await storage.run(operation)
            publish(result)
            return result
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func publish(_ value: DeliveryWorkflowSnapshot) {
        if snapshot != value { snapshot = value }
        if error != nil { error = nil }
    }

    func reload() async {
        _ = await enqueue({ try $0.load() }) { [self] result in
            switch result {
            case .success(let value): publish(value)
            case .failure(let failure):
                error = "Inbox local indisponível. Os dados existentes foram preservados: \(failure.localizedDescription)"
            }
        }
    }

    @discardableResult
    func update(_ operation: @escaping @Sendable (DeliveryWorkflowRepository) throws -> DeliveryWorkflowSnapshot) async -> Bool {
        let result = await enqueue(operation) { [self] result in
            switch result {
            case .success(let value): publish(value)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        if case .success = result { return true }
        return false
    }

    func loadSnapshot() async throws -> DeliveryWorkflowSnapshot {
        let result = await enqueue({ try $0.load() }) { [self] result in
            if case .success(let value) = result { publish(value) }
        }
        return try result.get()
    }

    func exportMetrics() async throws -> DeliveryMetricsExport {
        let result = await enqueue({ try $0.exportMetrics() }, publish: { _ in })
        return try result.get()
    }

    func observe(_ agents: [EngineAgent]) async {
        if snapshot == nil { await reload() }
        guard snapshot != nil else { return }
        let observations = agents.compactMap { agent in
            agent.deliveryReference.map { DeliveryAgentObservation(agentRef: $0, state: agent.state) }
        }
        _ = await enqueue({ repository in
            // Mutations re-read under lock and never overwrite corrupt JSON.
            try repository.observe(observations)
        }) { [self] result in
            switch result {
            case .success(let value):
                let previous = Set(snapshot?.interventions.map(\.id) ?? [])
                publish(value)
                let newCount = pending.filter { !previous.contains($0.id) }.count
                if newCount > 0 { Task { await notifications.announceNewItems(newCount) } }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func opened(_ ref: DeliveryAgentReference, panel: String) async {
        await update { repository in
            // Seeing an item is independent of delivering any input to its CLI.
            var value = try repository.load()
            for item in value.interventions where item.isPending && item.agentRef == ref && item.readAt == nil && interventionPanel(item) == panel {
                value = try repository.markRead(item.id)
            }
            return value
        }
    }

    func inputDelivered(_ ref: DeliveryAgentReference, sentAt: Date) async {
        await update { try $0.markInputDelivered(agentRef: ref, sentAt: sentAt) }
    }

    private struct CommentSave: Sendable {
        let snapshot: DeliveryWorkflowSnapshot?
        let refreshError: String?
    }

    /// A confirmed insert stays successful even if a subsequent read meets another instance's lock.
    func addComment(ref: DeliveryAgentReference, version: String, line: Int, text: String) async -> Bool {
        let result = await enqueue({ repository in
            _ = try repository.addComment(agentRef: ref, diffVersion: version, line: line, text: text)
            do { return CommentSave(snapshot: try repository.load(), refreshError: nil) }
            catch { return CommentSave(snapshot: nil, refreshError: error.localizedDescription) }
        }) { [self] result in
            switch result {
            case .success(let saved):
                if let value = saved.snapshot { publish(value) }
                if let failure = saved.refreshError {
                    error = "Nota salva. A atualização da lista falhou; releia a inbox para vê-la, sem salvar novamente: \(failure)"
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        if case .success = result { return true }
        return false
    }
}

extension EngineAgent {
    var deliveryReference: DeliveryAgentReference? {
        createdAtMs.map { DeliveryAgentReference(id: id, createdAtMs: $0) }
    }
}
