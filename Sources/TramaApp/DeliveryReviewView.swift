import SwiftUI
import TramaCore

private struct ReviewBatch: Identifiable {
    let id = UUID()
    let preview: EngineReviewPreview
    let comments: [DeliveryComment]
    let ref: DeliveryAgentReference
    let version: String
}

struct DeliveryReviewView: View {
    let client: OctoEngineClient
    let agent: EngineAgent
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    let didLoad: (EngineDiffSnapshot?) -> Void
    @State private var snapshot: EngineDiffSnapshot?
    @State private var loading = false
    @State private var acting = false
    @State private var error: String?
    @State private var notice: String?
    @State private var lineText = ""
    @State private var commentText = ""
    @State private var showsOldComments = false
    @State private var confirmReviewed = false
    @State private var batch: ReviewBatch?
    @State private var batchLimit = 32

    private var ref: DeliveryAgentReference? { agent.deliveryReference }
    private var comments: [DeliveryComment] {
        (workflow.snapshot?.comments ?? []).filter { $0.agentRef == ref }.sorted {
            $0.line == $1.line ? $0.createdAt < $1.createdAt : $0.line < $1.line
        }
    }
    private var currentComments: [DeliveryComment] { comments.filter { $0.diffVersion == snapshot?.version } }
    private var pendingComments: [DeliveryComment] { currentComments.filter { $0.resolvedAt == nil && $0.sentAt == nil } }
    private var batchComments: [DeliveryComment] { Array(pendingComments.prefix(batchLimit)) }
    private var validLine: Int? {
        guard let line = Int(lineText), snapshot?.commentableLines.contains(line) == true else { return nil }
        return line
    }
    private var canSend: Bool {
        agent.isAlive && ["idle", "done"].contains(agent.state) && agent.kind != "shell" &&
        agent.kind != "terminal" && agent.archived != true && ref != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Atualizar snapshot") { Task { await load() } }.disabled(loading || acting)
                if loading || acting { ProgressView(loading ? "Lendo alterações locais…" : "Validando operação…").controlSize(.small) }
                Spacer()
                Button("Concluir revisão…") { confirmReviewed = true }
                    .disabled(loading || acting || snapshot?.text.isEmpty != false || ref == nil || workflow.snapshot == nil)
            }
            if let snapshot {
                Text("Versão \(snapshot.version.prefix(12)) · HEAD \(snapshot.headOid.prefix(12)) · linhas do snapshot, começando em 1")
                    .foregroundStyle(TerminalTheme.secondary).textSelection(.enabled)
                diffLines(snapshot)
                if snapshot.text.isEmpty { Text("Nenhuma alteração disponível. Uma revisão vazia não pode ser concluída.").foregroundStyle(TerminalTheme.secondary) }
                if ref == nil { Text("Registro sem identidade de criação. Comentários, envio e métricas indisponíveis.").foregroundStyle(TerminalTheme.warning) }
                HStack {
                    TextField("Linha do snapshot", text: $lineText).frame(width: 150)
                        .accessibilityLabel("Número da linha de conteúdo do snapshot, começando em 1")
                    TextField("Comentário local sobre esta versão", text: $commentText, axis: .vertical).lineLimit(1...3)
                    Button("Salvar nota") {
                        guard let ref, let line = validLine else { return }
                        if workflow.addComment(ref: ref, version: snapshot.version, line: line, text: commentText) {
                            commentText = ""; lineText = ""
                        }
                    }.disabled(ref == nil || validLine == nil || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workflow.snapshot == nil || loading || acting)
                }.textFieldStyle(.roundedBorder)
                Text("Clique no número de uma linha de conteúdo do diff para comentar. Cabeçalhos não aceitam notas; as notas ficam nesta versão e nunca são comandos para um terminal.")
                    .foregroundStyle(TerminalTheme.secondary)
                commentList
                HStack {
                    Stepper("Até \(batchLimit) notas", value: $batchLimit, in: 1...32)
                        .fixedSize().disabled(loading || acting)
                    Button("Preparar lote de \(batchComments.count) notas…") { Task { await prepareBatch() } }
                        .disabled(!canSend || pendingComments.isEmpty || loading || acting || workflow.snapshot == nil)
                }
                Text("Notas abertas e não enviadas desta versão, em ordem de linha. Se o lote exceder 24 KB, reduza a quantidade para preparar uma nova prévia.")
                    .foregroundStyle(TerminalTheme.secondary)
                if !canSend {
                    Text("Envio disponível somente para uma IA viva, disponível ou concluída, sem aprovação pendente. Shell, IA trabalhando e sessão interrompida não recebem notas.")
                        .foregroundStyle(TerminalTheme.secondary)
                }
            } else if !loading { Text("Snapshot indisponível. Atualize para revisar alterações.").foregroundStyle(TerminalTheme.secondary) }
            if let error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let error = workflow.error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(TerminalTheme.accent).textSelection(.enabled) }
        }
        .task { await load() }
        .onChange(of: agent.state) { _, _ in batch = nil; didLoad(nil) }
        .sheet(item: $batch) { value in
            ReviewBatchConfirmation(batch: value, busy: acting, error: error) { Task { await send(value) } }
        }
        .alert("Concluir a revisão desta versão?", isPresented: $confirmReviewed) {
            Button("Cancelar", role: .cancel) { }
            Button("Concluir revisão") { Task { await finishReview() } }
        } message: {
            Text("A versão exibida será conferida novamente no motor. Esta decisão registra sua revisão local e não resolve comentários, aprova o CLI ou integra código.")
        }
    }

    private func diffLines(_ snapshot: EngineDiffSnapshot) -> some View {
        let commentable = snapshot.commentableLines
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .top, spacing: 10) {
                        Button("\(index + 1)") { lineText = String(index + 1) }
                            .buttonStyle(.plain).foregroundStyle(commentable.contains(index + 1) ? TerminalTheme.accent : TerminalTheme.secondary)
                            .disabled(!commentable.contains(index + 1))
                            .frame(width: 48, alignment: .trailing)
                            .accessibilityLabel("Comentar na linha \(index + 1) do snapshot")
                        Text(text.isEmpty ? " " : text).textSelection(.enabled)
                    }.font(TerminalTheme.mono(12)).padding(.vertical, 2)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 150, idealHeight: 220, maxHeight: 280)
            .overlay(Rectangle().stroke(TerminalTheme.border))
    }

    private var commentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(currentComments.count) notas nesta versão").accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Mostrar versões antigas (\(comments.count - currentComments.count))", isOn: $showsOldComments).toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(showsOldComments ? comments : currentComments) { comment in
                        DeliveryCommentRow(comment: comment, old: comment.diffVersion != snapshot?.version, workflow: workflow)
                    }
                    if currentComments.isEmpty && !showsOldComments { Text("Nenhuma nota nesta versão.").foregroundStyle(TerminalTheme.secondary) }
                }
            }.frame(maxHeight: 170)
        }
    }

    @MainActor private func load() async {
        guard !loading, !acting else { return }
        loading = true; error = nil; notice = nil; batch = nil; snapshot = nil; lineText = ""; didLoad(nil)
        defer { loading = false }
        do {
            let value = try await client.diffSnapshot(agentId: agent.id)
            try Task.checkCancellation()
            guard value.createdAtMs == ref?.createdAtMs else {
                snapshot = nil
                error = "A identidade do agente mudou ou não está disponível. Atualize o quadro e reabra os detalhes."
                return
            }
            snapshot = value
            didLoad(value)
        } catch is CancellationError { } catch { self.error = "Não foi possível ler as alterações: \(error.localizedDescription)" }
    }

    @MainActor private func finishReview() async {
        guard let snapshot, let ref, !snapshot.text.isEmpty, !loading, !acting else { return }
        acting = true; error = nil; notice = nil
        defer { acting = false }
        do {
            let current = try await client.diffSnapshot(agentId: agent.id)
            guard current.version == snapshot.version, current.createdAtMs == ref.createdAtMs, !current.text.isEmpty else {
                error = "O diff mudou. Atualize o snapshot e revise a versão atual antes de concluir."
                didLoad(nil)
                return
            }
            workflow.update { try workflow.repository.recordReviewedDelivery(agentRef: ref, diffVersion: current.version, diffIsEmpty: current.text.isEmpty) }
            if workflow.error == nil { notice = "Revisão desta versão concluída por sua decisão. Comentários mantidos." }
        } catch { self.error = "Não foi possível validar a versão atual: \(error.localizedDescription)" }
    }

    @MainActor private func prepareBatch() async {
        guard let snapshot, let ref, canSend, !pendingComments.isEmpty, !acting, !loading else { return }
        acting = true; error = nil; notice = nil
        defer { acting = false }
        let comments = batchComments
        do {
            let preview = try await client.previewReview(agentId: agent.id, createdAtMs: ref.createdAtMs,
                expectedVersion: snapshot.version, notes: comments.map { EngineReviewNote(line: $0.line, body: $0.text) })
            guard preview.version == snapshot.version, preview.createdAtMs == ref.createdAtMs,
                  preview.noteCount == comments.count else { throw EngineClientError.invalidResponse }
            batch = ReviewBatch(preview: preview, comments: comments, ref: ref, version: snapshot.version)
        } catch { self.error = "Lote não preparado. Atualize o diff se a versão mudou: \(error.localizedDescription)" }
    }

    @MainActor private func send(_ value: ReviewBatch) async {
        guard !acting, canSend, ref == value.ref else { return }
        acting = true; error = nil; notice = nil
        defer { acting = false }
        do {
            let saved = try workflow.repository.load()
            guard value.comments.allSatisfy({ comment in saved.comments.contains(comment) }) else {
                error = "As notas mudaram desde a prévia. Feche e prepare outro lote."
                return
            }
            let result = try await client.sendReview(agentId: agent.id, createdAtMs: value.ref.createdAtMs,
                expectedVersion: value.version, notes: value.comments.map { EngineReviewNote(line: $0.line, body: $0.text) },
                reviewToken: value.preview.token, confirmed: true)
            guard result.deliveredToPTY, result.agentId == agent.id, result.createdAtMs == value.ref.createdAtMs,
                  result.version == value.version, result.noteCount == value.comments.count else { throw EngineClientError.invalidResponse }
            workflow.update { try workflow.repository.markCommentsSent(value.comments) }
            batch = nil
            notice = workflow.error == nil
                ? "Lote entregue à IA. As notas continuam abertas até você resolvê-las explicitamente."
                : "Lote entregue, mas o registro local falhou. Não reenvie automaticamente; confira a IA antes de qualquer nova tentativa."
        } catch {
            self.error = "Envio sem confirmação de entrega; ele não será repetido automaticamente. Feche a prévia, confira o agente e atualize antes de preparar outro lote: \(error.localizedDescription)"
            batch = nil
        }
    }
}

private struct DeliveryCommentRow: View {
    let comment: DeliveryComment
    let old: Bool
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Linha \(comment.line) · versão \(comment.diffVersion.prefix(12)) · \(comment.resolvedAt != nil ? "resolvida" : "aberta")\(comment.sentAt != nil ? " · enviada" : " · não enviada")")
                .foregroundStyle(old ? TerminalTheme.warning : TerminalTheme.secondary)
            if old { Text("Versão antiga: esta nota não entrará no lote da versão atual.").foregroundStyle(TerminalTheme.warning) }
            if editing {
                TextField("Texto da nota", text: $text, axis: .vertical).lineLimit(1...5)
                HStack {
                    Button("Cancelar edição") { editing = false }
                    Button("Salvar edição") {
                        workflow.update { try workflow.repository.updateComment(comment.id, text: text) }
                        if workflow.error == nil { editing = false }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(comment.text).textSelection(.enabled)
                HStack {
                    Button("Editar nota") { text = comment.text; editing = true }.disabled(comment.resolvedAt != nil)
                    Button("Resolver nota") { workflow.update { try workflow.repository.resolveComment(comment.id) } }
                        .disabled(comment.resolvedAt != nil)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ReviewBatchConfirmation: View {
    let batch: ReviewBatch
    let busy: Bool
    let error: String?
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revisar lote antes de enviar à IA").font(TerminalTheme.mono(18, weight: .medium)).accessibilityAddTraits(.isHeader)
            Text("Este é o texto exato preparado pelo motor para \(batch.comments.count) notas da versão \(batch.version.prefix(12)). Enviar pode iniciar trabalho e uso pago do provedor. Aprovações permanecem no CLI.")
                .foregroundStyle(TerminalTheme.warning)
            ScrollView([.horizontal, .vertical]) {
                Text(batch.preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.overlay(Rectangle().stroke(TerminalTheme.border))
            Toggle("Revisei este lote e quero entregá-lo à IA viva", isOn: $confirmed).toggleStyle(.checkbox).disabled(busy)
            if let error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView("Enviando uma vez…").controlSize(.small) }
                Button("Enviar lote confirmado", action: send).disabled(!confirmed || busy)
            }
        }.padding(24).frame(width: 720, height: 560)
            .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.primary)
            .background(TerminalTheme.background).preferredColorScheme(.dark).interactiveDismissDisabled(busy)
    }
}
