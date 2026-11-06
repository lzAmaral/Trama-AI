import Foundation

public struct EngineAgent: Codable, Identifiable, Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let kind: String
    public let state: String
    public let session: String
    public let cwd: String
    public let project: String
    public let task: String
    public let activity: String
    public let branch: String?
    public let nested: EngineNested?

    public init(id: UInt32, name: String, kind: String, state: String, session: String,
                cwd: String, project: String, task: String, activity: String, branch: String? = nil, nested: EngineNested? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.session = session
        self.cwd = cwd
        self.project = project
        self.task = task
        self.activity = activity
        self.branch = branch
        self.nested = nested
    }

    public var isAlive: Bool { ["idle", "working", "paused", "done"].contains(state) }
}

public struct EngineSessionList: Codable, Sendable, Equatable {
    public let agents: [EngineAgent]
    public let sessions: [String]

    public init(agents: [EngineAgent], sessions: [String]) {
        self.agents = agents
        self.sessions = sessions
    }
}

public struct EngineSnapshot: Codable, Sendable, Equatable {
    public let data: String
    public let rows: Int
    public let cols: Int

    public init(data: String, rows: Int, cols: Int) {
        self.data = data
        self.rows = rows
        self.cols = cols
    }

    public var bytes: Data? { Data(base64Encoded: data) }
}

public struct EngineSkill: Codable, Identifiable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let invocation: String
    public var id: String { invocation }
}

public struct EngineRequest: Codable, Sendable {
    public var operation: String
    public var agentId: UInt32?
    public var kind: String?
    public var cwd: String?
    public var name: String?
    public var task: String?
    public var session: String?
    public var isolate: Bool?
    public var input: String?
    public var rows: Int?
    public var cols: Int?
    public var message: String?
    public var confirmed: Bool?

    public init(operation: String, agentId: UInt32? = nil, kind: String? = nil,
                cwd: String? = nil, name: String? = nil, task: String? = nil,
                session: String? = nil, isolate: Bool? = nil, input: String? = nil,
                rows: Int? = nil, cols: Int? = nil, message: String? = nil, confirmed: Bool? = nil) {
        self.operation = operation
        self.agentId = agentId
        self.kind = kind
        self.cwd = cwd
        self.name = name
        self.task = task
        self.session = session
        self.isolate = isolate
        self.input = input
        self.rows = rows
        self.cols = cols
        self.message = message
        self.confirmed = confirmed
    }
}

public struct EngineNested: Codable, Sendable, Equatable {
    public let kind: String
    public let pid: UInt32
    public let cwd: String?
    public let sinceMs: UInt64

    enum CodingKeys: String, CodingKey {
        case kind, pid, cwd
        case sinceMs = "since_ms"
    }
}

public struct EngineLog: Codable, Sendable, Equatable {
    public let text: String
    public let truncated: Bool
}

public struct EngineUsage: Codable, Sendable, Equatable {
    public let kind: String
    public let limits: EngineUsageLimits?
    public let problem: String?
    public let updatedAtMs: UInt64
}

public struct EngineUsageLimits: Codable, Sendable, Equatable {
    public let session: EngineUsageWindow?
    public let weekly: EngineUsageWindow?
    public let monthly: EngineUsageWindow?
    public let credits: Double?
}

public struct EngineUsageWindow: Codable, Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAtMs: UInt64?
}
