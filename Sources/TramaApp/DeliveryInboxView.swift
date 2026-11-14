import SwiftUI
import TramaCore

struct DeliveryInboxView: View {
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    let agents: [EngineAgent]
    let openAgent: (EngineAgent, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var onlyPending = true
    @State private var onlyUnread = false

    private var items: [DeliveryIntervention] {
        (workflow.snapshot?.interventions ?? []).filter {
            (!onlyPending || $0.isPending) && (!onlyUnread || $0.readAt == nil)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Inbox local · \(workflow.pending.count) pendentes").font(TerminalTheme.mono(18, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Abrir o painel do item marca como visto e não responde ao CLI. A resposta é registrada somente depois de uma entrada entregue com sucesso; a intervenção pode continuar pendente.")
                .foregroundStyle(TerminalTheme.secondary)
            HStack {
                Toggle("Somente pendentes", isOn: $onlyPending).toggleStyle(.checkbox)
                Toggle("Somente não vistos", isOn: $onlyUnread).toggleStyle(.checkbox)
                Spacer()
                Button("Reler inbox") { workflow.reload() }
            }
            if let error = workflow.error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if workflow.snapshot == nil {
                Text("Os dados locais não foram carregados. A gravação permanece bloqueada até uma leitura válida.")
                    .foregroundStyle(TerminalTheme.warning)
                Text(workflow.repository.fileURL.path).foregroundStyle(TerminalTheme.secondary).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if items.isEmpty && workflow.snapshot != nil { Text("Nenhum item neste filtro.").foregroundStyle(TerminalTheme.secondary).padding(.vertical, 20) }
                    ForEach(items, id: \.id) { item in row(item) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 760, height: 600)
            .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary)
            .background(TerminalTheme.background).preferredColorScheme(.dark)
    }

    private func row(_ item: DeliveryIntervention) -> some View {
        let agent = agents.first { $0.deliveryReference == item.agentRef }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(interventionTitle(item)).foregroundStyle(item.isPending ? TerminalTheme.warning : TerminalTheme.secondary)
                Spacer()
                Text(item.readAt == nil ? "Não visto" : "Visto")
            }
            Text(agent.map { "\($0.name) · #\($0.id) · \($0.session)" } ?? "Registro #\(item.agentRef.id) indisponível nesta atualização")
            Text(item.createdAt.formatted()).foregroundStyle(TerminalTheme.secondary)
            if item.kind == .paused || item.kind == .lost {
                Text(item.inputDeliveredAt == nil ? "Sem entrada entregue registrada" : "Entrada entregue ao CLI")
                    .foregroundStyle(TerminalTheme.secondary)
            }
            if let version = item.sourceVersion {
                Text("\(item.sourceRepository ?? "PR") #\(item.sourcePullRequestNumber.map { String($0) } ?? "?") · HEAD \(version.prefix(12))")
                    .foregroundStyle(TerminalTheme.secondary)
            }
            if item.reviewedAt != nil { Text("Revisão concluída explicitamente").foregroundStyle(TerminalTheme.accent) }
            else if item.dismissedAt != nil { Text("Dispensado pelo usuário").foregroundStyle(TerminalTheme.secondary) }
            else if !item.isPending { Text("Item encerrado após atualização").foregroundStyle(TerminalTheme.secondary) }
            HStack {
                if let agent {
                    Button("Abrir agente") {
                        workflow.update { try workflow.repository.markRead(item.id) }
                        dismiss()
                        openAgent(agent, interventionPanel(item))
                    }
                }
                Spacer()
                if item.isPending {
                    Button("Dispensar item") { workflow.update { try workflow.repository.dismissIntervention(item.id) } }
                        .help("Fecha apenas o item local; não envia entrada, aprova CLI ou conclui revisão")
                }
            }
        }.padding(14).background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}

func interventionTitle(_ item: DeliveryIntervention) -> String {
    switch item.kind {
    case .paused: "Precisa de você"
    case .lost: "Sessão interrompida"
    case .reviewAvailable: "Entrega disponível para revisão"
    case .checksFailed: "Checks de PR precisam de atenção"
    }
}

func interventionPanel(_ item: DeliveryIntervention) -> String {
    switch item.kind {
    case .reviewAvailable: "diff"
    case .checksFailed: "pr"
    case .paused, .lost: "terminal"
    }
}
