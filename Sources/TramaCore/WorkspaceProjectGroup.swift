import Foundation

/// Project-first presentation of global engine sessions. A shared session appears in each
/// participating project, with only that project's non-archived agents underneath it.
public struct WorkspaceProjectGroup: Identifiable, Equatable, Sendable {
    public var id: UUID { project.id }
    public let project: Project
    public let agents: [EngineAgent]
    public let sessions: [String]

    public static func groups(projects: [Project], agents: [EngineAgent], catalog: [ProjectSession] = []) -> [Self] {
        let visible = agents.filter { $0.archived != true }
        return projects.map { project in
            let members = visible.filter { WorkspaceNavigationState.matches(agent: $0, project: project) }
            return Self(project: project, agents: members,
                        sessions: ProjectSession.sessions(for: project, agents: members, catalog: catalog))
        }
    }
}
