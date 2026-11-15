import SwiftUI
import TramaCore

/// A shared engine session is shown in each project containing its agents.
struct ProjectSidebarView: View {
    let projects: [Project]
    @ObservedObject var model: LiveWorkspaceModel
    let addProject: () -> Void
    let createSession: (UUID?) -> Void
    @State private var expandedProjects: Set<UUID> = []
    @State private var expandedSessions: Set<SessionKey> = []
    @State private var showsOtherSessions = false

    private struct SessionKey: Hashable {
        let projectID: UUID?
        let name: String
    }

    private var groups: [WorkspaceProjectGroup] {
        WorkspaceProjectGroup.groups(projects: projects, agents: model.agents)
    }

    var body: some View {
        let groups = groups
        let groupedIDs = Set(groups.flatMap(\.agents).map(\.id))
        let otherAgents = model.agents.filter { $0.archived != true && !groupedIDs.contains($0.id) }
        let usedSessions = Set(groups.flatMap(\.sessions))
        let otherSessions = model.sessions.filter { name in !usedSessions.contains(name) || otherAgents.contains(where: { $0.session == name }) }
        VStack(alignment: .leading, spacing: 4) {
            Button { model.selectScope(projectID: nil, session: nil) } label: {
                Label("Todos os projetos", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(model.navigation.selectedProjectID == nil && model.navigation.selectedSession == nil ? TerminalTheme.raised : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            ForEach(groups) { group in projectRow(group) }
            Button(action: addProject) {
                Label("Adicionar projeto", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.buttonStyle(.plain).foregroundStyle(TerminalTheme.secondary)
            if !otherSessions.isEmpty {
                DisclosureGroup("Outras sessões", isExpanded: $showsOtherSessions) {
                    Text("Sessões vazias ou com agentes fora dos projetos cadastrados. Aqui, a sessão abre com todos os seus projetos.")
                        .font(TerminalTheme.ui(11)).foregroundStyle(TerminalTheme.muted).padding(.vertical, 6)
                    ForEach(otherSessions, id: \.self) { name in
                        sessionRow(name, projectID: nil, agents: model.agents.filter { $0.session == name && $0.archived != true })
                    }
                }.font(TerminalTheme.ui(12)).foregroundStyle(TerminalTheme.secondary).padding(10)
            }
            if !model.hasLoaded { ProgressView("Carregando…").controlSize(.small).padding(10) }
        }
        .disabled(model.busy)
        .onAppear { revealSelection() }
        .onChange(of: model.navigation.selectedProjectID) { _, _ in revealSelection() }
        .onChange(of: model.navigation.selectedSession) { _, _ in revealSelection() }
    }

    private func revealSelection() {
        if let id = model.navigation.selectedProjectID { expandedProjects.insert(id) }
        if let name = model.navigation.selectedSession {
            expandedSessions.insert(SessionKey(projectID: model.navigation.selectedProjectID, name: name))
            if model.navigation.selectedProjectID == nil { showsOtherSessions = true }
        }
    }

    private func projectRow(_ group: WorkspaceProjectGroup) -> some View {
        let id = group.project.id
        let expanded = expandedProjects.contains(id)
        let selected = model.navigation.selectedProjectID == id
        var sessions = group.sessions
        if selected, let name = model.navigation.selectedSession, model.sessions.contains(name), !sessions.contains(name) { sessions.append(name) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    if expanded { expandedProjects.remove(id) } else { expandedProjects.insert(id) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 34)
                }.accessibilityLabel("\(expanded ? "Recolher" : "Expandir") projeto \(group.project.name)")
                Button {
                    model.selectScope(projectID: id, session: nil)
                    expandedProjects.insert(id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(TerminalTheme.accent)
                        Text(group.project.name).lineLimit(2).truncationMode(.middle).fontWeight(selected ? .semibold : .regular)
                        Spacer(minLength: 0)
                        Text("\(group.agents.count)").font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.muted)
                    }.frame(minHeight: 34).contentShape(Rectangle())
                }.help(group.project.name).accessibilityLabel("Projeto \(group.project.name), \(group.agents.count) agentes")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }.buttonStyle(.plain).padding(.horizontal, 6)
                .background(selected ? TerminalTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions.sorted(), id: \.self) { name in
                        sessionRow(name, projectID: id, agents: group.agents.filter { $0.session == name })
                    }
                    if sessions.isEmpty {
                        Text("Nenhuma sessão ainda").font(TerminalTheme.ui(11)).foregroundStyle(TerminalTheme.muted).padding(8)
                    }
                    Button { createSession(id) } label: {
                        Label("Nova sessão", systemImage: "plus").font(TerminalTheme.ui(12)).padding(8)
                    }.buttonStyle(.plain).foregroundStyle(TerminalTheme.secondary)
                }.padding(.leading, 20)
            }
        }
    }

    private func sessionRow(_ name: String, projectID: UUID?, agents: [EngineAgent]) -> some View {
        let key = SessionKey(projectID: projectID, name: name)
        let expanded = expandedSessions.contains(key)
        let selected = model.navigation.selectedProjectID == projectID && model.navigation.selectedSession == name
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    if expanded { expandedSessions.remove(key) } else { expandedSessions.insert(key) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 16, height: 30)
                }.accessibilityLabel("\(expanded ? "Recolher" : "Expandir") sessão \(name)")
                Button {
                    model.selectScope(projectID: projectID, session: name)
                    expandedSessions.insert(key)
                } label: {
                    HStack {
                        Text(name).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(agents.count)").font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
                    }.frame(minHeight: 30).contentShape(Rectangle())
                }.accessibilityLabel("Sessão \(name), \(agents.count) agentes")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }.buttonStyle(.plain).font(TerminalTheme.ui(12)).padding(.horizontal, 4)
                .background(selected ? TerminalTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
            if expanded {
                ForEach(agents) { agent in
                    Button { model.open(agent) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: liveStateSymbol(agent.state)).foregroundStyle(liveStateColor(agent.state))
                            Text(agent.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }.font(TerminalTheme.mono(11)).padding(.leading, 18).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(TerminalTheme.secondary)
                        .help("\(agent.name) · \(agent.kind) · \(liveStateTitle(agent.state))")
                }
            }
        }
    }
}
