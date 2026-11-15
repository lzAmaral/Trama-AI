import SwiftUI
import TramaCore

/// The native counterpart to Octo's explicit composer/agent workspace separation.
/// Reference: Octo f66aa85 desktop/ui/index.html and js/agent.js (MIT); no source copied.
struct AgentPromptComposer: View {
    @ObservedObject var model: LiveWorkspaceModel
    let agent: EngineAgent
    let identityAvailable: Bool
    @State private var sending = false
    @State private var notice: String?
    @State private var editorFocused = false

    private var draft: Binding<String> {
        Binding(get: {
            agent.deliveryReference.flatMap { model.promptDrafts[$0] } ?? ""
        }, set: { text in
            if let ref = agent.deliveryReference { model.promptDrafts[ref] = text }
        })
    }
    private var acceptsPrompt: Bool {
        identityAvailable && agent.archived != true && agent.kind != "terminal" &&
        ["idle", "done"].contains(agent.state)
    }
    private var hasTerminalControls: Bool {
        Self.hasTerminalControls(draft.wrappedValue)
    }

    static func hasTerminalControls(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
        }
    }
    private var valid: Bool {
        acceptsPrompt && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        draft.wrappedValue.utf8.count <= 23_987 && !hasTerminalControls && !sending && !model.busy
    }
    private var availability: String? {
        if !identityAvailable { return "Atualize o quadro e reabra este agente para enviar." }
        if agent.archived == true { return "Worktree arquivado. Envio indisponível." }
        if agent.kind == "terminal" { return "Shell interativo: digite comandos diretamente no terminal acima." }
        switch agent.state {
        case "paused": return "Responda à aprovação do provedor no terminal acima."
        case "working": return "O agente está ocupado. Aguarde para enviar outra instrução."
        case "lost": return "Use Retomar para recuperar esta sessão existente."
        case "exited": return "Este agente está encerrado. Inicie uma nova tarefa no projeto."
        case "idle", "done": return nil
        default: return "O agente ainda não está disponível para receber instruções."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Próxima instrução").fontWeight(.medium).fixedSize()
                Text(agent.kind.capitalized).foregroundStyle(TerminalTheme.providerColor(agent.kind))
                    .lineLimit(1).truncationMode(.middle).help(agent.kind)
                Spacer(minLength: 0)
            }
            Text(agent.cwd).font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.secondary).lineLimit(1)
                .truncationMode(.middle).textSelection(.enabled).help(agent.cwd)
                .accessibilityLabel("Pasta do agente: \(agent.cwd)")
            ZStack(alignment: .topLeading) {
                ComposerTextEditor(text: draft, isFocused: $editorFocused,
                                   isEditable: !sending && !model.busy && identityAvailable &&
                                    agent.kind != "terminal" && agent.archived != true && agent.state != "exited",
                                   fontSize: 13, accessibilityLabel: "Instrução para \(agent.name)",
                                   accessibilityIdentifier: "agent-prompt-editor")
                    .id(agent.deliveryReference).padding(.horizontal, 8)
                if draft.wrappedValue.isEmpty {
                    Text("Como o agente deve continuar?")
                        .foregroundStyle(TerminalTheme.secondary)
                        .padding(.horizontal, 8).padding(.top, 6).allowsHitTesting(false)
                }
            }
            .frame(height: 52).background(TerminalTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(editorFocused ? TerminalTheme.strongBorder : TerminalTheme.border))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    availabilityLabel.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    sendAction
                }
                VStack(alignment: .leading, spacing: 8) {
                    availabilityLabel
                    HStack { Spacer(minLength: 0); sendAction }
                }
            }
            if draft.wrappedValue.utf8.count > 23_987 {
                Text("A instrução excede o limite de 23.987 bytes. Divida o texto antes de enviar.")
                    .foregroundStyle(TerminalTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if hasTerminalControls {
                Text("O texto contém caracteres de controle. Remova-os para enviar; seu rascunho foi preservado.")
                    .foregroundStyle(TerminalTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let notice {
                Text(notice).foregroundStyle(TerminalTheme.accent).lineLimit(3).help(notice)
            }
        }
        .font(TerminalTheme.ui(12))
    }

    private var availabilityLabel: some View {
        Text(availability ?? "⌘Return para enviar")
            .foregroundStyle(TerminalTheme.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(availability ?? "⌘Return para enviar")
    }

    private var sendAction: some View {
        HStack(spacing: 8) {
            if sending { ProgressView().controlSize(.small) }
            Button("Enviar instrução", systemImage: "arrow.up", action: send)
                .accessibilityLabel("Enviar instrução a \(agent.name)")
                .accessibilityIdentifier("agent-prompt-send")
                .buttonStyle(NativeActionButtonStyle(primary: true)).lineLimit(1)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!valid)
        }.fixedSize()
    }

    private func send() {
        guard valid, let ref = agent.deliveryReference else { return }
        let text = draft.wrappedValue
        // Set synchronously, before scheduling the task, to reject a second click/shortcut.
        sending = true
        notice = nil
        Task { @MainActor in
            defer { sending = false }
            await model.perform {
                guard model.agents.contains(where: {
                    $0.deliveryReference == ref && $0.kind == agent.kind &&
                    $0.archived != true && ["idle", "done"].contains($0.state)
                }) else { throw EngineClientError.invalidRequest }
                let sentAt = Date()
                let result = try await model.client.sendPrompt(agentId: ref.id, createdAtMs: ref.createdAtMs,
                                                               text: text, confirmed: true)
                guard result.deliveredToPTY else { throw EngineClientError.invalidResponse }
                if model.promptDrafts[ref] == text { model.promptDrafts[ref] = nil }
                await model.workflow.inputDelivered(ref, sentAt: sentAt)
                notice = "Entregue ao terminal de \(agent.name). Acompanhe a resposta acima."
            }
            if model.error != nil {
                notice = "Texto preservado. Confira o terminal antes de tentar de novo: a entrega pode ter ocorrido."
            }
        }
    }
}
