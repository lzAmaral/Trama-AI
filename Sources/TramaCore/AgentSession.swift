import Foundation
import CryptoKit

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let name: String
    public let provider: String
    public let status: AgentStatus
    public let summary: String
    public let activity: [String]

    public init(id: UUID = UUID(), projectID: UUID, projectName: String, name: String,
                provider: String, status: AgentStatus, summary: String, activity: [String]) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.name = name
        self.provider = provider
        self.status = status
        self.summary = summary
        self.activity = activity
    }
}

public enum AgentBoardQuery {
    public static func filter(_ sessions: [AgentSession], projectID: UUID?, search: String) -> [AgentSession] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            (projectID == nil || session.projectID == projectID) &&
            (query.isEmpty || [session.name, session.projectName, session.provider, session.summary]
                .contains { $0.localizedStandardContains(query) })
        }
    }
}

/// Fixtures only. These records never represent running processes or persist as user projects.
public enum DemoSessions {
    private static let exampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static func make(projects: [Project]) -> [AgentSession] {
        let contexts = projects.isEmpty
            ? [Project(id: exampleID, name: "Trama · exemplo", path: "")]
            : projects
        return contexts.flatMap { project in
            [
                session(project, slot: 0, name: "revisao-interface", provider: "Codex", status: .needsAttention,
                        summary: "Exemplo: decidir a organização da navegação",
                        activity: ["Plano de interface preparado", "Solicitação fictícia de revisão registrada"]),
                session(project, slot: 1, name: "painel-agentes", provider: "Claude Code", status: .working,
                        summary: "Exemplo: construindo a visão geral de agentes",
                        activity: ["Estrutura do painel planejada", "Etapa fictícia de implementação registrada"]),
                session(project, slot: 2, name: "testes-persistencia", provider: "Codex", status: .completed,
                        summary: "Exemplo: revisão dos cenários de persistência concluída",
                        activity: ["Cenários de teste organizados", "Conclusão demonstrativa; nenhum teste executado pelo painel"]),
                session(project, slot: 3, name: "documentacao", provider: "Claude Code", status: .idle,
                        summary: "Exemplo: aguardando uma nova tarefa",
                        activity: ["Sessão fictícia disponível; nenhum processo iniciado"])
            ]
        }
    }

    private static func session(_ project: Project, slot: UInt8, name: String, provider: String,
                                status: AgentStatus, summary: String, activity: [String]) -> AgentSession {
        // Stable namespaced identities for fixtures across view recomputations.
        let bytes = Array(SHA256.hash(data: Data("trama-demo/\(project.id)/\(slot)".utf8)))
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return AgentSession(id: id, projectID: project.id, projectName: project.name,
                            name: name, provider: provider, status: status, summary: summary, activity: activity)
    }
}
