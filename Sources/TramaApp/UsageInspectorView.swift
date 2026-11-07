import SwiftUI
import TramaCore

struct UsageInspectorView: View {
    let provider: EngineProvider
    @Environment(\.dismiss) private var dismiss
    @State private var usage: EngineUsage?
    @State private var error: String?
    @State private var pending: Task<Void, Never>?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Consumo · \(provider.id)").font(TerminalTheme.mono(20, weight: .medium))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Esta consulta usa as credenciais existentes do CLI para acessar o serviço do provedor. Os limites dependem do seu tipo de conta e da compatibilidade da integração.")
                .foregroundStyle(TerminalTheme.secondary)
            Text("A consulta é manual. O Trama não registra os tokens nem consulta consumo em segundo plano.")
                .foregroundStyle(TerminalTheme.secondary)
            TerminalRule()
            if loading { ProgressView("Consultando provedor…") }
            if let error { Text(error).foregroundStyle(TerminalTheme.warning) }
            if let usage {
                if let problem = usage.problem { Text("Consulta indisponível: \(problem)").foregroundStyle(TerminalTheme.warning) }
                if let limits = usage.limits {
                    if let window = limits.session { quota("Janela atual", window) }
                    if let window = limits.weekly { quota("Semanal", window) }
                    if let window = limits.monthly { quota("Mensal", window) }
                    if let credits = limits.credits { Text("Saldo informado: \(credits, specifier: "%.2f")") }
                    if limits.session == nil && limits.weekly == nil && limits.monthly == nil && limits.credits == nil {
                        Text("O provedor não retornou limites para esta conta.")
                    }
                }
                Text("Consultado em \(Date(timeIntervalSince1970: Double(usage.updatedAtMs) / 1000).formatted(date: .omitted, time: .standard))")
                    .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.secondary)
            }
            Spacer(minLength: 0)
            Button("Consultar agora") {
                pending = Task { await fetchUsage() }
            }.buttonStyle(.borderedProminent).disabled(loading)
        }
        .padding(24).frame(width: 560, height: 520)
        .font(TerminalTheme.mono(13)).foregroundStyle(TerminalTheme.primary)
        .background(TerminalTheme.background).preferredColorScheme(.dark)
        .onDisappear { pending?.cancel() }
    }

    private func quota(_ title: String, _ window: EngineUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text("\(window.usedPercent, specifier: "%.0f")% usado") }
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100).tint(TerminalTheme.accent)
                .accessibilityLabel("Consumo: \(title)")
                .accessibilityValue(Text("\(window.usedPercent, specifier: "%.0f") por cento usado"))
            if let reset = window.resetsAtMs {
                Text("Renova em \(Date(timeIntervalSince1970: Double(reset) / 1000).formatted())")
                    .font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
            }
        }
    }

    @MainActor private func fetchUsage() async {
        guard !loading else { return }
        guard !Task.isCancelled else { return }
        loading = true; error = nil; usage = nil
        defer { loading = false }
        do {
            let client = OctoEngineClient(executableURL: OctoEngineClient.defaultExecutableURL, homeURL: OctoEngineClient.defaultHomeURL)
            let result = try await client.usage(kind: provider.id, confirmed: true)
            try Task.checkCancellation()
            usage = result
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}
