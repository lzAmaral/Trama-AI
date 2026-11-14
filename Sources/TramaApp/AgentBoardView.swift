import SwiftUI
import TramaCore

/// Demo presentation adapted from Octo desktop/ui (MIT), reference 1dc08a44.
struct AgentBoardView: View {
    let projects: [Project]
    let showsDemo: Bool

    @Binding private var projectFilter: UUID?
    @State private var search = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var mode: BoardDisplayMode = .board
    @State private var selectedSession: AgentSession?

    init(projects: [Project], selectedProjectID: Binding<UUID?>, showsDemo: Bool) {
        self.projects = projects
        self.showsDemo = showsDemo
        _projectFilter = selectedProjectID
    }

    private let statuses: [AgentStatus] = [.needsAttention, .working, .completed, .idle]

    private var sessions: [AgentSession] {
        showsDemo ? DemoSessions.make(projects: projects) : []
    }

    private var filteredSessions: [AgentSession] {
        AgentBoardQuery.filter(sessions, projectID: projectFilter, search: search)
    }

    private var projectOptions: [BoardProjectOption] {
        var names: [UUID: String] = [:]
        for project in projects { names[project.id] = project.name }
        for session in sessions { names[session.projectID] = session.projectName }
        return names.map { BoardProjectOption(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewTab
            header.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            if !showsDemo {
                boardMessage("Nenhum agente conectado", detail: "Desative Demonstração para acompanhar sessões reais.")
            } else if filteredSessions.isEmpty {
                boardMessage("Nenhum resultado", detail: "Experimente outro termo ou selecione todos os projetos.")
            } else if mode == .board {
                board
            } else {
                list
            }
            TerminalRule()
            Text("Demonstração · tarefas e atividades fictícias, sem processos em execução")
                .font(TerminalTheme.ui(11))
                .foregroundStyle(TerminalTheme.secondary)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(TerminalTheme.background)
        .foregroundStyle(TerminalTheme.primary)
        .font(TerminalTheme.ui(13))
        .background {
            Button("Buscar agentes demonstrativos") { showsSearch = true }.keyboardShortcut("f").hidden()
        }
        .onChange(of: showsDemo) { _, _ in selectedSession = nil }
        .sheet(item: $selectedSession) { session in
            BoardSessionDetail(session: session)
        }
    }

    private var overviewTab: some View {
        HStack(spacing: 8) {
            Label("Visão geral", systemImage: "rectangle.split.3x1")
                .font(TerminalTheme.ui(12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 30)
                .background(TerminalTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityAddTraits(.isSelected)
            Spacer()
            Text("Demonstração").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.muted)
        }.padding(.horizontal, 12).frame(height: 44)
            .overlay(alignment: .bottom) { TerminalRule() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                heading
                Spacer(minLength: 8)
                headActions
            }
            VStack(alignment: .leading, spacing: 16) {
                heading
                HStack { Spacer(minLength: 0); headActions }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Demonstração").font(TerminalTheme.ui(30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                Text("\(filteredSessions.count) agentes fictícios em \(Set(filteredSessions.map(\.projectID)).count) projetos")
                    .foregroundStyle(TerminalTheme.secondary)
                let waiting = filteredSessions.filter { $0.status == .needsAttention }.count
                if waiting > 0 {
                    Text(" · \(waiting) precisam de você").foregroundStyle(TerminalTheme.warning)
                }
            }.font(TerminalTheme.ui(12))
            Text("Nenhum processo é iniciado nesta visualização")
                .font(TerminalTheme.ui(11)).foregroundStyle(TerminalTheme.muted)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var headActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Todos os projetos") { projectFilter = nil }
                ForEach(projectOptions) { project in
                    Button(project.name) { projectFilter = project.id }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(projectOptions.first { $0.id == projectFilter }?.name ?? "Todos os projetos")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(TerminalTheme.ui(9))
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .padding(.horizontal, 10).frame(width: 200, height: 32)
                .help(projectOptions.first { $0.id == projectFilter }?.name ?? "Todos os projetos")
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(TerminalTheme.border))
                .accessibilityLabel("Filtrar por projeto")
            HStack(spacing: 2) {
                displayMode("Quadro", value: .board)
                displayMode("Lista", value: .list)
            }.padding(3).background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            Button { showsSearch.toggle() } label: {
                Image(systemName: "magnifyingglass").frame(width: 28, height: 30)
            }.buttonStyle(.plain)
                .foregroundStyle(search.isEmpty ? TerminalTheme.secondary : TerminalTheme.accent)
                .accessibilityLabel("Buscar agentes demonstrativos").help("Buscar agentes (⌘F)")
                .popover(isPresented: $showsSearch) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Buscar agentes demonstrativos").font(TerminalTheme.ui(14, weight: .medium))
                        TextField("Nome, projeto ou provedor", text: $search)
                            .textFieldStyle(.roundedBorder).focused($searchFocused)
                            .accessibilityLabel("Buscar agente, projeto ou provedor")
                        if !search.isEmpty { Button("Limpar busca") { search = "" } }
                    }.padding(20).frame(width: 320).onAppear { searchFocused = true }
                }
        }.font(TerminalTheme.ui(12))
    }

    private func displayMode(_ title: String, value: BoardDisplayMode) -> some View {
        Button { mode = value } label: {
            Text(title).font(TerminalTheme.ui(12, weight: .semibold))
                .foregroundStyle(mode == value ? TerminalTheme.primary : TerminalTheme.secondary)
                .padding(.horizontal, 10).frame(height: 28)
                .background(mode == value ? TerminalTheme.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityLabel("Visualização em \(title.lowercased())")
            .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private var board: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(statuses, id: \.rawValue) { status in
                        let columnSessions = filteredSessions.filter { $0.status == status }
                        VStack(alignment: .leading, spacing: 12) {
                            BoardColumnHeading(status: status, count: columnSessions.count)
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    if columnSessions.isEmpty {
                                        Text("Nenhum agente neste estado")
                                            .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.muted)
                                            .padding(.vertical, 12)
                                    }
                                    ForEach(columnSessions) { session in
                                        demoCard(session)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 4)
                            }.frame(maxHeight: .infinity)
                        }.frame(width: max(240, (geometry.size.width - 112) / 4), alignment: .topLeading)
                    }
                }
                .frame(height: max(0, geometry.size.height - 16), alignment: .topLeading)
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
        }
    }

    private func demoCard(_ session: AgentSession) -> some View {
        BoardSessionCard(session: session,
                         projectPath: projects.first { $0.id == session.projectID }?.path ?? session.projectName) {
            selectedSession = session
        }
    }

    private var list: some View {
        ScrollView {
            if filteredSessions.isEmpty {
                boardMessage("Nenhum resultado", detail: "Experimente outro termo ou selecione todos os projetos.")
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(statuses, id: \.rawValue) { status in
                        let rows = filteredSessions.filter { $0.status == status }
                        VStack(alignment: .leading, spacing: 12) {
                            BoardColumnHeading(status: status, count: rows.count)
                            ForEach(rows) { session in
                                demoCard(session)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func boardMessage(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(TerminalTheme.ui(20, weight: .medium))
            Text(detail).foregroundStyle(TerminalTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum BoardDisplayMode: Hashable { case board, list }
private struct BoardProjectOption: Identifiable { let id: UUID; let name: String }

private struct BoardColumnHeading: View {
    let status: AgentStatus
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: boardSymbol(status)).foregroundStyle(boardColor(status))
            Text(status.title).foregroundStyle(TerminalTheme.primary)
            Spacer(minLength: 4)
            Text("\(count)").monospacedDigit().foregroundStyle(TerminalTheme.secondary)
        }
        .font(TerminalTheme.ui(13, weight: .semibold))
        .frame(height: 24)
        .padding(.bottom, 4)
    }
}

private struct BoardSessionCard: View {
    let session: AgentSession
    let projectPath: String
    let open: () -> Void

    private var providerKind: String {
        session.provider.localizedCaseInsensitiveContains("claude") ? "claude" : session.provider.lowercased()
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: boardSymbol(session.status))
                        .font(.system(size: 12)).foregroundStyle(boardColor(session.status)).frame(width: 14)
                    Text(session.name).font(TerminalTheme.mono(13, weight: .semibold))
                        .foregroundStyle(session.status == .idle ? TerminalTheme.secondary : TerminalTheme.primary)
                        .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(TerminalTheme.projectColor(projectPath))
                        .frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(session.projectName).foregroundStyle(TerminalTheme.secondary).lineLimit(2)
                        .truncationMode(.middle).fixedSize(horizontal: false, vertical: true).help(session.projectName)
                    Text("·").foregroundStyle(TerminalTheme.muted)
                    Text(providerKind).foregroundStyle(TerminalTheme.providerColor(providerKind)).fixedSize()
                }.font(TerminalTheme.mono(11)).padding(.leading, 22)
                VStack(alignment: .leading, spacing: 4) {
                    if session.status == .needsAttention {
                        Text("Aguardando sua resposta").font(TerminalTheme.ui(13, weight: .semibold))
                            .foregroundStyle(TerminalTheme.warning)
                    }
                    Text(session.summary).font(TerminalTheme.ui(13))
                        .foregroundStyle(session.status == .idle ? TerminalTheme.secondary : TerminalTheme.primary)
                        .lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(WorkspaceCardStyle(state: session.status == .needsAttention ? "paused" : nil))
        .help("Abrir exemplo: \(session.name)")
        .accessibilityLabel("Abrir detalhes de \(session.name), \(session.projectName), \(session.provider), \(session.status.title), demonstração")
    }
}

private struct BoardSessionDetail: View {
    let session: AgentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Detalhes do agente").font(TerminalTheme.ui(18, weight: .medium))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Label("Sessão fictícia · nenhum processo em execução", systemImage: "info.circle")
                .font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.warning)
            TerminalRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.name).font(TerminalTheme.ui(20, weight: .medium))
                    Label(session.status.title, systemImage: boardSymbol(session.status))
                        .foregroundStyle(boardColor(session.status))
                    Text("Projeto: \(session.projectName)")
                    Text("Provedor: \(session.provider)")
                    Text(session.summary).foregroundStyle(TerminalTheme.secondary)
                    TerminalRule()
                    Text("Atividade demonstrativa").font(TerminalTheme.ui(13, weight: .medium))
                    ForEach(Array(session.activity.enumerated()), id: \.offset) { index, line in
                        Text(String(format: "%03d", index + 1) + "  " + line)
                            .font(TerminalTheme.mono(12))
                            .foregroundStyle(TerminalTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 560, height: 500)
        .background(TerminalTheme.background)
        .foregroundStyle(TerminalTheme.primary)
        .font(TerminalTheme.ui(13))
        .preferredColorScheme(.dark)
    }
}

private func boardColor(_ status: AgentStatus) -> Color {
    switch status {
    case .needsAttention: TerminalTheme.warning
    case .working: TerminalTheme.warning
    case .completed: TerminalTheme.positive
    case .idle: TerminalTheme.secondary
    }
}

private func boardSymbol(_ status: AgentStatus) -> String {
    switch status {
    case .needsAttention: "pause.fill"
    case .working: "circle.dotted"
    case .completed: "checkmark.circle"
    case .idle: "circle"
    }
}
