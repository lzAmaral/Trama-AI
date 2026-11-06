import Foundation

public struct Project: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public enum AgentStatus: String, CaseIterable, Sendable {
    case working, needsAttention, completed

    public var title: String {
        switch self {
        case .working: "Em andamento"
        case .needsAttention: "Precisa de você"
        case .completed: "Concluído"
        }
    }
}
