import SwiftUI
import TramaCore

struct AgentBoardView: View {
    let projects: [Project]
    let showsDemo: Bool

    @Binding private var projectFilter: UUID?
    @State private var search = ""
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
            header.padding(24)
            TerminalRule()
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
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
                .padding(16)
        }
        .background(TerminalTheme.background)
        .foregroundStyle(TerminalTheme.primary)
        .font(TerminalTheme.mono(13))
        .background {
            Button("Buscar agentes demonstrativos") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .onChange(of: showsDemo) { _, _ in selectedSession = nil }
        .sheet(item: $selectedSession) { session in
            BoardSessionDetail(session: session)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(">").foregroundStyle(TerminalTheme.accent)
                Text("Visão geral").font(TerminalTheme.mono(24, weight: .medium))
                Spacer(minLength: 8)
            }
            Text("\(filteredSessions.count) agentes · \(Set(filteredSessions.map(\.projectID)).count) projetos · \(filteredSessions.filter { $0.status == .needsAttention }.count) precisam de você")
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsDemo {
                Text("[demo] Dados fictícios · nenhum agente em execução")
                    .font(TerminalTheme.mono(12))
                    .foregroundStyle(TerminalTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    projectPicker.frame(width: 210)
                    searchField.frame(minWidth: 180)
                    modePicker.frame(width: 156)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        projectPicker
                        modePicker.frame(width: 156)
                    }
                    searchField
                }
            }
        }
    }

    private var projectPicker: some View {
        Picker("Projeto", selection: $projectFilter) {
            Text("Todos os projetos").tag(nil as UUID?)
            ForEach(projectOptions) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .labelsHidden()
        .accessibilityLabel("Filtrar por projeto")
    }

    private var searchField: some View {
        TextField("Buscar agente, projeto ou provedor", text: $search)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Buscar agente, projeto ou provedor").focused($searchFocused)
    }

    private var modePicker: some View {
        Picker("Visualização", selection: $mode) {
            Text("Quadro").tag(BoardDisplayMode.board)
            Text("Lista").tag(BoardDisplayMode.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Visualização dos agentes")
    }

    private var board: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(statuses, id: \.rawValue) { status in
                        let columnSessions = filteredSessions.filter { $0.status == status }
                        VStack(alignment: .leading, spacing: 12) {
                            BoardColumnHeading(status: status, count: columnSessions.count)
                            if columnSessions.isEmpty {
                                Text("Nenhum agente neste estado")
                                    .font(TerminalTheme.mono(12))
                                    .foregroundStyle(TerminalTheme.secondary)
                                    .padding(.vertical, 16)
                            }
                            ForEach(columnSessions) { session in
                                BoardSessionCard(session: session) { selectedSession = session }
                            }
                        }
                        .frame(width: max(240, (geometry.size.width - 96) / 4), alignment: .topLeading)
                    }
                }
                .padding(24)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
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
                                BoardSessionCard(session: session) { selectedSession = session }
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
            Text("[info] \(title)").foregroundStyle(TerminalTheme.accent)
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
            Label(status.title, systemImage: boardSymbol(status))
                .foregroundStyle(boardColor(status))
            Spacer(minLength: 4)
            Text("\(count)").foregroundStyle(TerminalTheme.secondary)
        }
        .font(TerminalTheme.mono(12, weight: .medium))
        .padding(.bottom, 4)
    }
}

private struct BoardSessionCard: View {
    let session: AgentSession
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.name)
                .font(TerminalTheme.mono(13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.projectName).foregroundStyle(TerminalTheme.secondary)
                Text(session.provider).foregroundStyle(TerminalTheme.accent)
            }
            .font(TerminalTheme.mono(12))
            .fixedSize(horizontal: false, vertical: true)
            TerminalRule()
            if session.status == .needsAttention {
                Text("Aguardando sua resposta · exemplo")
                    .font(TerminalTheme.mono(12, weight: .medium))
                    .foregroundStyle(TerminalTheme.warning)
            }
            Text(session.summary)
                .font(TerminalTheme.mono(12))
                .foregroundStyle(TerminalTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Abrir detalhes", action: open)
                .buttonStyle(.bordered)
                .tint(session.status == .needsAttention ? TerminalTheme.warning : TerminalTheme.accent)
                .accessibilityLabel("Abrir detalhes de \(session.name)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(session.status == .needsAttention ? TerminalTheme.warning.opacity(0.6) : TerminalTheme.border))
    }
}

private struct BoardSessionDetail: View {
    let session: AgentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Detalhes do agente").font(TerminalTheme.mono(18, weight: .medium))
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("[demo] Sessão fictícia · nenhum processo em execução")
                .font(TerminalTheme.mono(12)).foregroundStyle(TerminalTheme.warning)
            TerminalRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.name).font(TerminalTheme.mono(20, weight: .medium))
                    Label(session.status.title, systemImage: boardSymbol(session.status))
                        .foregroundStyle(boardColor(session.status))
                    Text("Projeto: \(session.projectName)")
                    Text("Provedor: \(session.provider)")
                    Text(session.summary).foregroundStyle(TerminalTheme.secondary)
                    TerminalRule()
                    Text("Atividade demonstrativa").font(TerminalTheme.mono(13, weight: .medium))
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
        .font(TerminalTheme.mono(13))
        .preferredColorScheme(.dark)
    }
}

private func boardColor(_ status: AgentStatus) -> Color {
    switch status {
    case .needsAttention: TerminalTheme.warning
    case .working: TerminalTheme.primary
    case .completed: TerminalTheme.accent
    case .idle: TerminalTheme.secondary
    }
}

private func boardSymbol(_ status: AgentStatus) -> String {
    switch status {
    case .needsAttention: "pause.circle.fill"
    case .working: "circle.dotted"
    case .completed: "checkmark.circle"
    case .idle: "circle"
    }
}
