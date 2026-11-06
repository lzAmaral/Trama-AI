import SwiftUI
import TramaCore

struct EngineInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: EngineInspection?
    @State private var failure: String?
    @State private var isLoading = false
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("trama > motor local").font(TerminalTheme.mono(18, weight: .medium))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Verificação real de instalação · não inicia agentes")
                .foregroundStyle(TerminalTheme.accent)
            Text("Os provedores precisam estar instalados e autenticados separadamente. Esta verificação detecta executáveis; não consulta credenciais ou cotas.")
                .foregroundStyle(TerminalTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TerminalRule()
            if isLoading {
                ProgressView("Verificando motor…")
            } else if let failure {
                Text(failure).foregroundStyle(TerminalTheme.warning)
                    .textSelection(.enabled)
            } else if let inspection {
                HStack {
                    Text("[ok] Motor disponível")
                        .foregroundStyle(TerminalTheme.accent)
                    Spacer()
                    Text("\(inspection.agentCount) registros locais")
                        .foregroundStyle(TerminalTheme.secondary)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(inspection.providers) { provider in
                            HStack {
                                Text(provider.id)
                                Spacer()
                                Label(provider.installed ? "Detectado" : "Não encontrado",
                                      systemImage: provider.installed ? "checkmark.circle" : "minus.circle")
                                    .foregroundStyle(provider.installed ? TerminalTheme.accent : TerminalTheme.secondary)
                            }
                            .padding(.vertical, 10)
                            TerminalRule()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Controle de sessões e terminal ainda em integração. O quadro continua demonstrativo.")
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
            Button("Verificar novamente") { requestID = UUID() }
                .disabled(isLoading)
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .font(TerminalTheme.mono(13))
        .foregroundStyle(TerminalTheme.primary)
        .background(TerminalTheme.background)
        .preferredColorScheme(.dark)
        .task(id: requestID) { await inspect() }
    }

    @MainActor
    private func inspect() async {
        isLoading = true
        failure = nil
        inspection = nil
        defer { isLoading = false }
        do {
            let client = OctoEngineClient(executableURL: OctoEngineClient.defaultExecutableURL,
                                         homeURL: OctoEngineClient.defaultHomeURL)
            let result = try await client.inspect()
            try Task.checkCancellation()
            inspection = result
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }
}
