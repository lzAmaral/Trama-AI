import Foundation
import SwiftUI
import TramaCore

@MainActor
final class DeliveryWorkflowViewModel: ObservableObject {
    @Published private(set) var snapshot: DeliveryWorkflowSnapshot?
    @Published private(set) var error: String?
    let repository: DeliveryWorkflowRepository
    let notifications = DeliveryNotifications()

    init(engineHome: URL) {
        repository = DeliveryWorkflowRepository(engineHome: engineHome)
        reload()
    }

    var pending: [DeliveryIntervention] {
        (snapshot?.interventions ?? []).filter(\.isPending).sorted { $0.createdAt < $1.createdAt }
    }
    var unreadCount: Int { pending.filter { $0.readAt == nil }.count }

    func reload() {
        do { snapshot = try repository.load(); error = nil }
        catch { self.error = "Inbox local indisponível. Os dados existentes foram preservados: \(error.localizedDescription)" }
    }

    func update(_ operation: () throws -> DeliveryWorkflowSnapshot) {
        do { snapshot = try operation(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func observe(_ agents: [EngineAgent]) {
        guard snapshot != nil else { return }
        let previous = Set(snapshot?.interventions.map(\.id) ?? [])
        update {
            try repository.observe(agents.compactMap { agent in
                agent.deliveryReference.map { DeliveryAgentObservation(agentRef: $0, state: agent.state) }
            })
        }
        let newCount = pending.filter { !previous.contains($0.id) }.count
        if newCount > 0 { Task { await notifications.announceNewItems(newCount) } }
    }

    func opened(_ ref: DeliveryAgentReference, panel: String) {
        // Seeing an item is independent of delivering any input to its CLI.
        for item in pending where item.agentRef == ref && item.readAt == nil && interventionPanel(item) == panel {
            update { try repository.markRead(item.id) }
        }
    }

    func inputDelivered(_ ref: DeliveryAgentReference, sentAt: Date) {
        update { try repository.markInputDelivered(agentRef: ref, sentAt: sentAt) }
    }

    /// A confirmed insert stays successful even if a subsequent read meets another instance's lock.
    func addComment(ref: DeliveryAgentReference, version: String, line: Int, text: String) -> Bool {
        do {
            _ = try repository.addComment(agentRef: ref, diffVersion: version, line: line, text: text)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        do {
            snapshot = try repository.load()
            error = nil
        } catch {
            self.error = "Nota salva. A atualização da lista falhou; releia a inbox para vê-la, sem salvar novamente: \(error.localizedDescription)"
        }
        return true
    }
}

extension EngineAgent {
    var deliveryReference: DeliveryAgentReference? {
        createdAtMs.map { DeliveryAgentReference(id: id, createdAtMs: $0) }
    }
}
