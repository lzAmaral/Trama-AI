import AppKit
import SwiftUI
import TramaCore
import UniformTypeIdentifiers

struct DeliveryPilotView: View {
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportText = ""
    @State private var notice: String?

    private var enabled: Bool { workflow.snapshot?.metrics.enabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Piloto local e alertas").font(TerminalTheme.mono(18, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("O piloto é opcional e fica neste Mac. A exportação contém apenas contagens e tempos de uso, sem conteúdo, nomes, identificadores de agentes ou caminhos. Nada é enviado automaticamente.")
                .foregroundStyle(TerminalTheme.secondary)
            Text("Mede criação → primeira entrega revisada, intervenção → abertura e intervenção → entrada entregue separadamente. Abrir um agente não conta como resposta; visitas são agrupadas em janelas de 30 minutos.")
                .foregroundStyle(TerminalTheme.secondary)
            HStack {
                Text(enabled ? "Piloto ativado" : "Piloto desativado")
                Spacer()
                Button(enabled ? "Desativar e limpar métricas" : "Participar do piloto local") {
                    workflow.update { try workflow.repository.setMetricsEnabled(!enabled) }
                    if workflow.snapshot?.metrics.enabled == true {
                        workflow.update { try workflow.repository.recordVisit() }
                    }
                    exportText = ""; notice = nil
                }.disabled(workflow.snapshot == nil)
            }
            Text("Ao ativar, começa uma nova janela de medição. Desativar apaga somente as métricas; sua inbox, comentários e vínculos de PR permanecem.")
                .foregroundStyle(TerminalTheme.secondary)
            Text("As métricas são calculadas localmente. O armazenamento funcional mantém identidades, notas e PRs para os fluxos do aplicativo; esses dados não entram na exportação agregada.")
                .foregroundStyle(TerminalTheme.secondary)
            Button("Preparar exportação de contagens e tempos") { prepareExport() }.disabled(workflow.snapshot == nil)
            if !exportText.isEmpty {
                ScrollView {
                    Text(exportText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 150).padding(10).overlay(Rectangle().stroke(TerminalTheme.border))
                Button("Salvar este agregado…") { saveExport() }
            }
            TerminalRule()
            DeliveryNotificationSettings(notifications: workflow.notifications)
            if let error = workflow.error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).textSelection(.enabled) }
            Spacer(minLength: 0)
        }.padding(24).frame(width: 720, height: 680)
            .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary)
            .background(TerminalTheme.background).preferredColorScheme(.dark)
    }

    private func prepareExport() {
        do {
            let value = try workflow.repository.exportMetrics()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            exportText = String(decoding: try encoder.encode(value), as: UTF8.self)
            notice = nil
        } catch { notice = "Não foi possível preparar o agregado: \(error.localizedDescription)" }
    }

    private func saveExport() {
        guard !exportText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Salvar métricas agregadas do piloto local"
        panel.nameFieldStringValue = "trama-piloto-agregado.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(exportText.utf8).write(to: url, options: .atomic)
            notice = "Agregado salvo em \(url.path)."
        } catch { notice = "Não foi possível salvar: \(error.localizedDescription)" }
    }
}
