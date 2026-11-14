import AppKit
import SwiftUI
import TramaCore
import UniformTypeIdentifiers

struct LogExportView: View {
    let client: OctoEngineClient
    let agentID: UInt32
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var redactions = ""
    @State private var preview: EngineLogExport?
    @State private var reviewed = false
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pending: Task<Void, Never>?

    private var redactionLines: [String] { redactions.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    private var validRedactions: Bool {
        redactionLines.count <= 32 && redactionLines.allSatisfy { $0.utf8.count <= 1024 } && redactionLines.reduce(0) { $0 + $1.utf8.count } <= 8192
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Exportar histórico · \(name)").font(TerminalTheme.mono(18, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("O histórico pode conter comandos, dados pessoais e segredos. A revisão é manual: confira todo o texto antes de salvar ou compartilhar.")
                .foregroundStyle(TerminalTheme.warning)
            Text("Trechos a ocultar (um texto literal por linha, opcional)")
            TextEditor(text: $redactions).frame(height: 70)
                .accessibilityLabel("Trechos literais a ocultar na exportação, um por linha")
                .overlay(Rectangle().stroke(TerminalTheme.border))
            HStack {
                Button("Preparar prévia local") { pending = Task { await prepare() } }.disabled(loading || !validRedactions)
                if loading { ProgressView("Preparando…").controlSize(.small) }
            }
            if !validRedactions { Text("Use até 32 trechos de até 1.024 bytes cada, com no máximo 8 KiB no total.").foregroundStyle(TerminalTheme.warning) }
            if let preview {
                Text(preview.warning).foregroundStyle(TerminalTheme.warning).fixedSize(horizontal: false, vertical: true)
                if preview.truncated { Text("Histórico truncado: somente o trecho abaixo será exportado.").foregroundStyle(TerminalTheme.warning) }
                Text("Texto exato que será salvo").accessibilityAddTraits(.isHeader)
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.text.isEmpty ? "" : preview.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(minHeight: 200).overlay(Rectangle().stroke(TerminalTheme.border))
                if preview.text.isEmpty { Text("O histórico exportável está vazio.").foregroundStyle(TerminalTheme.secondary) }
                Toggle("Revisei este texto e os possíveis dados sensíveis", isOn: $reviewed).toggleStyle(.checkbox)
                Button("Salvar texto revisado…") { save(preview.text) }
                    .buttonStyle(.borderedProminent).disabled(!reviewed || loading || preview.text.isEmpty)
            }
            if let error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).textSelection(.enabled) }
        }.padding(24).frame(width: 720, height: 700)
            .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary)
            .background(TerminalTheme.background).preferredColorScheme(.dark)
            .onChange(of: redactions) { _, _ in preview = nil; reviewed = false; notice = nil }
            .onDisappear { pending?.cancel() }
    }

    @MainActor private func prepare() async {
        guard !loading, validRedactions else { return }
        let requestedRedactions = redactions
        loading = true; error = nil; notice = nil; preview = nil; reviewed = false
        defer { loading = false }
        do {
            let result = try await client.exportLogs(agentId: agentID,
                redactions: requestedRedactions.components(separatedBy: .newlines).filter { !$0.isEmpty }, confirmed: true)
            try Task.checkCancellation()
            guard requestedRedactions == redactions else { return }
            preview = result
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    @MainActor private func save(_ reviewedText: String) {
        guard reviewed else { return }
        let panel = NSSavePanel()
        panel.title = "Salvar histórico revisado"
        panel.nameFieldStringValue = "trama-agente-\(agentID).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Persist exactly the reviewed snapshot. Never fetch another log after approval.
            try Data(reviewedText.utf8).write(to: url, options: .atomic)
            notice = "Texto revisado salvo em \(url.path)."
            error = nil
        } catch { self.error = "Não foi possível salvar: \(error.localizedDescription)" }
    }
}

struct LogRetentionView: View {
    let client: OctoEngineClient
    @Environment(\.dismiss) private var dismiss
    @State private var ageDays = "30"
    @State private var fileMiB = "16"
    @State private var plan: EngineLogRetentionPlan?
    @State private var loading = false
    @State private var applying = false
    @State private var confirmsRemoval = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pending: Task<Void, Never>?

    private var age: UInt32? { UInt32(ageDays) }
    private var bytes: UInt64? {
        guard let value = UInt64(fileMiB), value > 0, value <= UInt64.max / 1_048_576 else { return nil }
        return value * 1_048_576
    }
    private var valid: Bool {
        (ageDays.isEmpty || age.map { (1...3650).contains($0) } == true) && (fileMiB.isEmpty || bytes.map { $0 <= 1_073_741_824 } == true) && !(ageDays.isEmpty && fileMiB.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Retenção manual de logs").font(TerminalTheme.mono(18, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
            }
            Text("Revise os arquivos candidatos antes de excluir. Nenhuma política será aplicada automaticamente; esta ação remove apenas os logs listados.")
                .foregroundStyle(TerminalTheme.secondary)
            Form {
                TextField("Idade mínima em dias (opcional)", text: $ageDays)
                TextField("Tamanho mínimo por arquivo em MiB (opcional)", text: $fileMiB)
            }.disabled(loading || applying)
            Text("Use 1–3.650 dias ou 1–1.024 MiB; preencha pelo menos um critério. Os critérios selecionam logs antigos ou grandes de agentes encerrados.")
                .foregroundStyle(TerminalTheme.secondary)
            HStack {
                Button("Revisar candidatos") { pending = Task { await loadPlan() } }.disabled(!valid || loading || applying)
                if loading || applying { ProgressView(applying ? "Excluindo logs revisados…" : "Lendo candidatos…").controlSize(.small) }
            }
            if let plan {
                Text("\(plan.candidates.count) arquivos · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.totalBytes), countStyle: .file))")
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if plan.candidates.isEmpty { Text("Nenhum arquivo atende aos critérios.") }
                        ForEach(Array(plan.candidates.enumerated()), id: \.offset) { _, candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.path).textSelection(.enabled)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: candidate.bytes), countStyle: .file))
                                    .foregroundStyle(TerminalTheme.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 160)
                Button("Excluir arquivos revisados…", role: .destructive) { confirmsRemoval = true }
                    .disabled(plan.candidates.isEmpty || loading || applying)
            }
            if let error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent) }
            Spacer(minLength: 0)
        }.padding(24).frame(width: 680, height: 580)
            .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary)
            .background(TerminalTheme.background).preferredColorScheme(.dark)
            .interactiveDismissDisabled(applying)
            .onChange(of: ageDays) { _, _ in plan = nil; notice = nil }
            .onChange(of: fileMiB) { _, _ in plan = nil; notice = nil }
            .onDisappear { if !applying { pending?.cancel() } }
            .alert("Excluir os logs revisados?", isPresented: $confirmsRemoval) {
                Button("Cancelar", role: .cancel) { }
                Button("Excluir", role: .destructive) { pending = Task { await applyPlan() } }
            } message: {
                Text("Serão excluídos permanentemente \(plan?.candidates.count ?? 0) arquivos da prévia. Se os arquivos mudaram desde a revisão, prepare outra prévia. Esta ação não pode ser desfeita.")
            }
    }

    @MainActor private func loadPlan() async {
        guard valid, !loading, !applying else { return }
        loading = true; error = nil; notice = nil; plan = nil
        defer { loading = false }
        do {
            let result = try await client.logRetention(maxAgeDays: age, maxFileBytes: bytes)
            try Task.checkCancellation()
            plan = result
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }

    @MainActor private func applyPlan() async {
        guard let reviewedPlan = plan, !applying, !loading else { return }
        applying = true; error = nil; notice = nil
        defer { applying = false; plan = nil }
        do {
            let result = try await client.applyLogRetention(planToken: reviewedPlan.planToken, confirmed: true)
            notice = "\(result.removedFiles) arquivos excluídos · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: result.removedBytes), countStyle: .file))."
        } catch { self.error = "Não foi possível concluir a exclusão. Revise uma nova prévia antes de tentar novamente: \(error.localizedDescription)" }
    }
}
