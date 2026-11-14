import SwiftUI
import TramaCore

/// Native, read-only counterpart to Octo's grid view.
/// Layout reference: Octo 1dc08a4 desktop/ui/js/grid.js (MIT, Lucas Marujo).
/// A page owns at most six snapshot tasks; previews never send PTY input or resize.
struct WorkspaceTerminalGrid: View {
    let agents: [EngineAgent]
    let client: OctoEngineClient
    let onOpen: (EngineAgent) -> Void
    @State private var page = 0

    private let pageSize = 6
    private var pageCount: Int { max(1, (agents.count + pageSize - 1) / pageSize) }
    private var displayedAgents: [EngineAgent] {
        Array(agents.dropFirst(min(page, pageCount - 1) * pageSize).prefix(pageSize))
    }

    var body: some View {
        GeometryReader { geometry in
            if agents.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 24, weight: .light))
                    Text("Nenhum agente nesta grade").font(TerminalTheme.ui(16, weight: .medium))
                    Text("Inicie uma tarefa abaixo ou ajuste os filtros.")
                        .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary)
                }
                .foregroundStyle(TerminalTheme.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Prévias somente leitura").font(TerminalTheme.ui(11))
                            .foregroundStyle(TerminalTheme.secondary)
                        Spacer(minLength: 0)
                        if pageCount > 1 {
                            Text("\(min(page, pageCount - 1) + 1) / \(pageCount)")
                                .font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
                                .accessibilityLabel("Página \(min(page, pageCount - 1) + 1) de \(pageCount)")
                            Button { page = max(0, page - 1) } label: {
                                Image(systemName: "chevron.left").frame(width: 20, height: 20)
                            }.buttonStyle(.plain).disabled(page == 0)
                                .accessibilityLabel("Página anterior de terminais")
                            Button { page = min(pageCount - 1, page + 1) } label: {
                                Image(systemName: "chevron.right").frame(width: 20, height: 20)
                            }.buttonStyle(.plain).disabled(page >= pageCount - 1)
                                .accessibilityLabel("Próxima página de terminais")
                        }
                    }
                    let columnCount = geometry.size.width >= 840 ? 3 : 2
                    let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: columnCount)
                    let tileHeight = min(280, max(176, (geometry.size.height - 36) / 2))
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(displayedAgents) { agent in
                                WorkspaceTerminalTile(agent: agent, client: client, compact: geometry.size.width / CGFloat(columnCount) < 280,
                                                      onOpen: { onOpen(agent) })
                                    .frame(height: tileHeight)
                                    .id(TerminalPreviewIdentity(agent))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(TerminalTheme.border))
                    }
                }
            }
        }
        .onChange(of: agents.map(TerminalPreviewIdentity.init)) { _, _ in
            page = min(page, pageCount - 1)
        }
    }
}

private struct TerminalPreviewIdentity: Hashable {
    let id: UInt32
    let createdAtMs: UInt64?

    init(_ agent: EngineAgent) {
        id = agent.id
        createdAtMs = agent.createdAtMs
    }
}

private struct TerminalPreviewPollKey: Equatable {
    let identity: TerminalPreviewIdentity
    let alive: Bool
}

private struct WorkspaceTerminalTile: View {
    let agent: EngineAgent
    let client: OctoEngineClient
    let compact: Bool
    let onOpen: () -> Void
    @State private var snapshot = Data()
    @State private var hasSnapshot = false
    @State private var error: String?

    private var pollKey: TerminalPreviewPollKey {
        TerminalPreviewPollKey(identity: TerminalPreviewIdentity(agent), alive: agent.isAlive && agent.archived != true)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                tileHeader
                    .padding(.horizontal, 12).frame(height: compact ? 52 : 36)
                    .background(liveStateColor(agent.state).opacity(agent.state == "paused" ? 0.12 : 0.06))
                TerminalRule()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                HStack(spacing: 6) {
                    Text(agent.archived == true ? "Arquivado" : liveStateTitle(agent.state))
                        .lineLimit(1).truncationMode(.tail).foregroundStyle(liveStateColor(agent.state))
                        .help(agent.archived == true ? "Arquivado" : liveStateTitle(agent.state))
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if hasSnapshot && !agent.isAlive {
                        if compact {
                            Image(systemName: "clock").foregroundStyle(TerminalTheme.secondary)
                                .help("Última captura desta sessão")
                        } else {
                            Text("Última captura").foregroundStyle(TerminalTheme.secondary).fixedSize()
                        }
                    }
                    Image(systemName: "arrow.up.right").foregroundStyle(TerminalTheme.secondary)
                }
                .font(TerminalTheme.ui(10)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(TerminalTheme.surface)
            }
            .background(TerminalTheme.background)
            .overlay(Rectangle().stroke(TerminalTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Abrir \(agent.name) · \(agent.project)")
        .accessibilityLabel("Abrir terminal de \(agent.name), agente \(agent.id), \(agent.kind), \(liveStateTitle(agent.state)). Prévia somente leitura.")
        .task(id: pollKey) { await poll() }
    }

    private var tileHeader: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 0) {
            HStack(spacing: 8) {
                Image(systemName: liveStateSymbol(agent.state))
                    .foregroundStyle(liveStateColor(agent.state)).frame(width: 12)
                Text(agent.name).font(TerminalTheme.mono(12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(TerminalTheme.primary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).help(agent.name)
                if !compact { providerAndID }
            }
            if compact {
                HStack(spacing: 8) {
                    providerAndID
                }.padding(.leading, 20)
            }
        }
    }

    private var providerAndID: some View {
        Group {
            Text(agent.kind).font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.providerColor(agent.kind))
                .lineLimit(1).truncationMode(.middle).help(agent.kind)
                .frame(minWidth: 0, maxWidth: compact ? .infinity : 80, alignment: .leading)
            Text("#\(agent.id)").font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted).fixedSize()
        }
    }

    @ViewBuilder private var preview: some View {
        if hasSnapshot {
            ZStack(alignment: .bottomLeading) {
                NativeTerminalView(snapshot: snapshot, name: agent.name, isInteractive: false,
                                   onInput: { _ in }, onResize: { _, _ in })
                    .allowsHitTesting(false).accessibilityHidden(true)
                if let error {
                    previewError(error)
                }
            }
        } else if agent.createdAtMs == nil {
            fallback("Atualize o motor para identificar este registro antes de obter a prévia.", symbol: "exclamationmark.circle")
        } else if !pollKey.alive {
            fallback(agent.activity.isEmpty ? "Abra o agente para consultar a tarefa e o histórico." : agent.activity,
                     symbol: "text.alignleft")
        } else if let error {
            fallback(error, symbol: "exclamationmark.triangle")
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Carregando terminal…").font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fallback(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(TerminalTheme.muted)
            Text(text).font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary)
                .lineLimit(4).multilineTextAlignment(.leading).help(text)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewError(_ text: String) -> some View {
        Label("Falha na atualização: \(text)", systemImage: "exclamationmark.triangle")
            .font(TerminalTheme.ui(10)).foregroundStyle(TerminalTheme.warning)
            .lineLimit(2).multilineTextAlignment(.leading).help(text).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TerminalTheme.surface)
    }

    @MainActor private func poll() async {
        guard agent.createdAtMs != nil, pollKey.alive else { return }
        while !Task.isCancelled {
            do {
                // This is a read-only snapshot. No input, resize, start or resume RPC is sent.
                let next = try await client.snapshot(agentId: agent.id)
                try Task.checkCancellation()
                guard let bytes = next.bytes else { throw EngineClientError.invalidResponse }
                if snapshot != bytes { snapshot = bytes }
                hasSnapshot = true
                error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
        }
    }
}
