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
    public let archived: Bool?
    public let parentId: UInt32?
    public let createdAtMs: UInt64?

    public init(id: UInt32, name: String, kind: String, state: String, session: String,
                cwd: String, project: String, task: String, activity: String, branch: String? = nil,
                nested: EngineNested? = nil, archived: Bool? = nil, parentId: UInt32? = nil,
                createdAtMs: UInt64? = nil) {
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
        self.archived = archived
        self.parentId = parentId
        self.createdAtMs = createdAtMs
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
    public var maxAgeDays: UInt32?
    public var maxFileBytes: UInt64?
    public var planToken: String?
    public var redactions: [String]?
    public var createdAtMs: UInt64?
    public var expectedVersion: String?
    public var reviewToken: String?
    public var notes: [EngineReviewNote]?
    public var number: Int?

    public init(operation: String, agentId: UInt32? = nil, kind: String? = nil,
                cwd: String? = nil, name: String? = nil, task: String? = nil,
                session: String? = nil, isolate: Bool? = nil, input: String? = nil,
                rows: Int? = nil, cols: Int? = nil, message: String? = nil, confirmed: Bool? = nil,
                maxAgeDays: UInt32? = nil, maxFileBytes: UInt64? = nil, planToken: String? = nil,
                redactions: [String]? = nil, createdAtMs: UInt64? = nil,
                expectedVersion: String? = nil, reviewToken: String? = nil,
                notes: [EngineReviewNote]? = nil, number: Int? = nil) {
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
        self.maxAgeDays = maxAgeDays
        self.maxFileBytes = maxFileBytes
        self.planToken = planToken
        self.redactions = redactions
        self.createdAtMs = createdAtMs
        self.expectedVersion = expectedVersion
        self.reviewToken = reviewToken
        self.notes = notes
        self.number = number
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

/// Archiving preserves the worktree in place, including ignored files, and does not free disk space.
public struct EngineWorktreeArchive: Codable, Sendable, Equatable {
    public let agentId: UInt32
    public let path: String
    public let branch: String
    public let archivedAtMs: UInt64
    public let preservesChanges: Bool
}

/// A bounded local process snapshot, never a complete logical subagent tree.
public struct EngineProcessTree: Codable, Sendable, Equatable {
    public let agentId: UInt32
    public let rootPid: UInt32?
    public let nodes: [EngineProcessNode]
    public let complete: Bool
    public let limitations: [String]
    public let observedAtMs: UInt64
}

public struct EngineProcessNode: Codable, Identifiable, Sendable, Equatable {
    public let pid: UInt32
    public let parentPid: UInt32?
    public let name: String
    public let kind: String?
    public var id: UInt32 { pid }
}

/// A manual cleanup preview. maxFileBytes is a per-file threshold, not a total storage quota.
public struct EngineLogRetentionPlan: Codable, Sendable, Equatable {
    public let planToken: String
    public let candidates: [EngineLogCandidate]
    public let totalBytes: UInt64
    public let maxAgeDays: UInt32?
    public let maxFileBytes: UInt64?
}

public struct EngineLogCandidate: Codable, Identifiable, Sendable, Equatable {
    public let path: String
    public let bytes: UInt64
    public var id: String { path }
}

public struct EngineLogRetentionResult: Codable, Sendable, Equatable {
    public let removedFiles: Int
    public let removedBytes: UInt64
}

/// Show and save this exact text after review; do not re-fetch logs during saving.
/// Literal redactions do not guarantee that all sensitive data has been removed.
public struct EngineLogExport: Codable, Sendable, Equatable {
    public let text: String
    public let truncated: Bool
    public let requiresSensitiveReview: Bool
    public let warning: String
}
