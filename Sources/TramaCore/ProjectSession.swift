import Foundation

/// Project-local labels; engine identities remain stable even while an agent is running.
public struct ProjectSession: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let engineID: String
    public var name: String
    public let managed: Bool

    public init(projectID: UUID, engineID: String, name: String, managed: Bool = true) {
        self.projectID = projectID
        self.engineID = engineID
        self.name = name
        self.managed = managed
    }

    public static func generalID(for projectID: UUID) -> String {
        projectID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func initialID(for projectID: UUID, catalog: [Self]) -> String {
        catalog.first { $0.projectID == projectID && $0.name == "Geral" }?.engineID ?? generalID(for: projectID)
    }

    public static func name(for engineID: String, projectID: UUID?, catalog: [Self]) -> String {
        if let entry = catalog.first(where: { $0.engineID == engineID && $0.projectID == projectID }) {
            return entry.name
        }
        if let projectID, engineID == generalID(for: projectID) { return "Geral" }
        if projectID == nil {
            let names = Set(catalog.filter { $0.engineID == engineID }.map(\.name))
            if names.count == 1, let name = names.first { return name }
            if names.count > 1 { return "Sessão compartilhada" }
        }
        return engineID
    }

    public static func sessions(for project: Project, agents: [EngineAgent], catalog: [Self]) -> [String] {
        let owned = catalog.filter { $0.projectID == project.id }.map(\.engineID)
        let existing = agents.filter { WorkspaceNavigationState.matches(agent: $0, project: project) }.map(\.session)
        return Array(Set(owned + existing + [initialID(for: project.id, catalog: catalog)])).sorted {
            let left = name(for: $0, projectID: project.id, catalog: catalog)
            let right = name(for: $1, projectID: project.id, catalog: catalog)
            return left == right ? $0 < $1 : left < right
        }
    }
}
