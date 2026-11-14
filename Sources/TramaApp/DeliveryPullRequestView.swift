import AppKit
import SwiftUI
import TramaCore

struct DeliveryPullRequestView: View {
    let client: OctoEngineClient
    let agent: EngineAgent
    @ObservedObject var workflow: DeliveryWorkflowViewModel
    @State private var number = ""
    @State private var confirmQuery = false
    @State private var loading = false
    @State private var localLoading = false
    @State private var local: EngineDiffSnapshot?
    @State private var localObservedAt: Date?
    @State private var error: String?
    @State private var localError: String?

    private var ref: DeliveryAgentReference? { agent.deliveryReference }
    private var link: DeliveryPullRequestLink? { workflow.snapshot?.pullRequestLinks.first { $0.agentRef == ref } }
    private var validNumber: Bool { number.isEmpty || Int(number).map { (1...Int(UInt32.max)).contains($0) } == true }
    private var staleReason: String {
        guard let link, let local, local.createdAtMs == ref?.createdAtMs, localError == nil else {
            return "Correspondência local desconhecida. Confira as alterações locais."
        }
        if link.diffVersion != local.version { return "Consulta obsoleta: o diff local mudou desde a consulta." }
        if link.localHeadOid != local.headOid { return "Consulta obsoleta: o HEAD local mudou desde a consulta." }
        if link.headOid != local.headOid { return "O HEAD do PR difere do HEAD local. Checks não validam esta versão local." }
        if !link.localDiffEmpty { return "Há alterações locais não representadas no HEAD consultado. Checks não validam essas alterações." }
        if let branch = agent.branch, branch != link.branch { return "A branch do agente difere da branch vinculada ao PR." }
        return "HEAD e versão coincidem com a última conferência local. Checks abaixo são apenas o snapshot da consulta manual."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PR e checks · consulta manual").font(TerminalTheme.mono(16, weight: .medium)).accessibilityAddTraits(.isHeader)
            Text("Consultar executa o GitHub CLI com suas credenciais e acessa a rede. Use o botão para autorizar cada consulta. O Trama apenas consulta e vincula um PR existente ao agente e à branch.")
                .foregroundStyle(TerminalTheme.warning)
            HStack {
                TextField("Número do PR (opcional)", text: $number).textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Consultar PR/CI…") { confirmQuery = true }
                    .disabled(loading || !validNumber || ref == nil || workflow.snapshot == nil)
                if loading { ProgressView("Consultando GitHub…").controlSize(.small) }
            }
            Text("Sem número, procura o PR da branch do agente. Não cria PR, faz push ou merge.")
                .foregroundStyle(TerminalTheme.secondary)
            if ref == nil { Text("Registro sem identidade de criação; vínculo persistente indisponível.").foregroundStyle(TerminalTheme.warning) }
            if let link {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(link.repository) #\(link.number) · \(link.title)").accessibilityAddTraits(.isHeader)
                        Text("Agente #\(link.agentRef.id) · branch \(link.branch) · estado \(link.state)")
                        Text("Última consulta: \(link.observedAt.formatted())").foregroundStyle(TerminalTheme.secondary)
                        Text("HEAD do PR: \(link.headOid)\nHEAD local na consulta: \(link.localHeadOid)")
                            .textSelection(.enabled).foregroundStyle(TerminalTheme.secondary)
                        Text(staleReason).foregroundStyle(TerminalTheme.warning)
                        HStack {
                            Button("Conferir alterações locais") { Task { await loadLocal() } }.disabled(localLoading || loading)
                            if localLoading { ProgressView().controlSize(.small) }
                            if let localObservedAt { Text("Conferido em \(localObservedAt.formatted())").foregroundStyle(TerminalTheme.secondary) }
                        }
                        if let localError { Text(localError).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
                        Text("Checks observados na consulta").accessibilityAddTraits(.isHeader)
                        if link.checks.isEmpty { Text("Nenhum check informado; isso não comprova CI aprovada.").foregroundStyle(TerminalTheme.secondary) }
                        ForEach(Array(link.checks.enumerated()), id: \.offset) { _, check in
                            Text("\(check.name) · \(check.state)\(check.conclusion.map { " · " + $0 } ?? "")")
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Abrir PR no navegador") {
                                if let url = validatedPullRequestURL(link) { NSWorkspace.shared.open(url) }
                            }.disabled(validatedPullRequestURL(link) == nil)
                            Spacer()
                            Button("Desvincular PR local") {
                                guard let ref else { return }
                                workflow.update { try workflow.repository.removePullRequestLink(agentRef: ref) }
                            }
                        }
                        if validatedPullRequestURL(link) == nil { Text("URL inválida ou fora do GitHub esperado. Abertura bloqueada.").foregroundStyle(TerminalTheme.warning) }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            } else {
                Text("Nenhum PR vinculado. A consulta só começa após sua confirmação.").foregroundStyle(TerminalTheme.secondary)
                Spacer(minLength: 0)
            }
            if let error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
            if let error = workflow.error { Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled) }
        }.frame(minHeight: 320)
        .task {
            if let link { number = String(link.number); await loadLocal() }
        }
        .alert("Consultar GitHub com suas credenciais?", isPresented: $confirmQuery) {
            Button("Cancelar", role: .cancel) { }
            Button("Autorizar esta consulta") { Task { await query() } }
        } message: {
            Text("O GitHub CLI acessará a rede usando sua autenticação existente para ler o PR e seus checks. Agente #\(agent.id), branch \(agent.branch ?? "da pasta do agente"). Nenhum PR será criado e nenhum código será enviado ou integrado.")
        }
    }

    @MainActor private func loadLocal() async {
        guard !localLoading else { return }
        localLoading = true; localError = nil
        defer { localLoading = false }
        do {
            let value = try await client.diffSnapshot(agentId: agent.id)
            try Task.checkCancellation()
            guard value.createdAtMs == ref?.createdAtMs else { throw EngineClientError.invalidResponse }
            local = value; localObservedAt = Date()
        } catch is CancellationError { } catch { self.localError = "Conferência local indisponível: \(error.localizedDescription)" }
    }

    @MainActor private func query() async {
        guard !loading, validNumber, let ref else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await client.githubPR(agentId: agent.id, createdAtMs: ref.createdAtMs, number: Int(number), confirmed: true)
            let value = DeliveryPullRequestLink(agentRef: ref, repository: result.repository, number: result.number,
                url: result.url, title: result.title, branch: result.branch, headOid: result.headOid,
                localHeadOid: result.localHeadOid, state: result.state, diffVersion: result.diffVersion,
                localDiffEmpty: result.localDiffEmpty,
                checks: result.checks.map { DeliveryPullRequestCheck(name: $0.name, state: $0.state, conclusion: $0.conclusion) },
                observedAt: Date(timeIntervalSince1970: Double(result.queriedAtMs) / 1000))
            guard validatedPullRequestURL(value) != nil else { throw EngineClientError.invalidResponse }
            let current = try await client.diffSnapshot(agentId: agent.id)
            guard current.createdAtMs == ref.createdAtMs else { throw EngineClientError.invalidResponse }
            workflow.update { try workflow.repository.setPullRequestLink(value) }
            local = current; localObservedAt = Date(); localError = nil
        } catch { self.error = "Consulta não concluída; nenhum retry automático: \(error.localizedDescription)" }
    }
}

/// Restrict opening to the exact HTTPS GitHub PR that the persisted identity names.
func validatedPullRequestURL(_ link: DeliveryPullRequestLink) -> URL? {
    guard link.number > 0, let components = URLComponents(string: link.url),
          components.scheme == "https", components.host?.lowercased() == "github.com",
          components.user == nil, components.password == nil, components.port == nil,
          components.query == nil, components.fragment == nil,
          components.path == "/\(link.repository)/pull/\(link.number)",
          link.repository.split(separator: "/").count == 2 else { return nil }
    return components.url
}
