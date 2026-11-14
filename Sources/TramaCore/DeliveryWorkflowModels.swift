import Foundation

/// The repository's engine home supplies the namespace; a recycled numeric ID is a new agent.
public struct DeliveryAgentReference: Codable, Hashable, Sendable {
    public let id: UInt32
    public let createdAtMs: UInt64

    public init(id: UInt32, createdAtMs: UInt64) {
        self.id = id
        self.createdAtMs = createdAtMs
    }
}

/// Supply only agents with a known creation timestamp from a successful engine snapshot.
public struct DeliveryAgentObservation: Sendable, Equatable {
    public let agentRef: DeliveryAgentReference
    public let state: String

    public init(agentRef: DeliveryAgentReference, state: String) {
        self.agentRef = agentRef
        self.state = state
    }
}

public struct DeliveryIntervention: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case paused, lost, reviewAvailable, checksFailed
    }

    public let id: UUID
    public let agentRef: DeliveryAgentReference
    public let kind: Kind
    public let createdAt: Date
    /// PR head for checksFailed. A terminal engine state cannot resolve this occurrence.
    public let sourceVersion: String?
    public let sourceRepository: String?
    public let sourcePullRequestNumber: Int?
    public internal(set) var readAt: Date?
    /// A successful PTY delivery acknowledgment, never provider approval or resolution.
    public internal(set) var inputDeliveredAt: Date?
    /// Only an observed known engine state can resolve paused/lost.
    public internal(set) var resolvedAt: Date?
    public internal(set) var dismissedAt: Date?
    public internal(set) var reviewedAt: Date?

    public var isPending: Bool { resolvedAt == nil && dismissedAt == nil && reviewedAt == nil }
}

/// `line` is 1-based in the exact diff text identified by `diffVersion`, not a source-file line.
public struct DeliveryComment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let agentRef: DeliveryAgentReference
    public let diffVersion: String
    public let line: Int
    public internal(set) var text: String
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var resolvedAt: Date?
    public internal(set) var sentAt: Date?
}

/// The only telemetry export. No identifiers, timestamps, prompts, comments, code or paths.
public struct DeliveryMetricsExport: Codable, Sendable, Equatable {
    public internal(set) var visits = 0
    public internal(set) var activeDays = 0
    public internal(set) var reviewedDeliveries = 0
    public internal(set) var openedInterventions = 0
    public internal(set) var deliveredInputs = 0
    public internal(set) var totalSecondsToOpen: Double = 0
    public internal(set) var totalSecondsToInput: Double = 0
    public internal(set) var secondsToFirstReviewedDelivery: Double?

    public init() {}
}

public struct DeliveryMetrics: Codable, Sendable, Equatable {
    public internal(set) var enabled = false
    public internal(set) var enabledAt: Date?
    public internal(set) var summary = DeliveryMetricsExport()
    var lastVisitAt: Date?
    var activeDates: [String] = []
    var reviewedAgents: [DeliveryAgentReference] = []

    public init() {}
}

public struct DeliveryPullRequestCheck: Codable, Sendable, Equatable {
    public let name: String
    public let state: String
    public let conclusion: String?

    public init(name: String, state: String, conclusion: String? = nil) {
        self.name = name
        self.state = state
        self.conclusion = conclusion
    }

    var isFailure: Bool {
        ["FAILURE", "ERROR"].contains(state.uppercased()) ||
        ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"]
            .contains(conclusion?.uppercased() ?? "")
    }

    var isConclusive: Bool {
        isFailure || state.uppercased() == "SUCCESS" ||
        (state.uppercased() == "COMPLETED" && ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion?.uppercased() ?? ""))
    }
}

/// A manual observation, not a live CI verdict. Compare head and diff version before displaying it.
public struct DeliveryPullRequestLink: Codable, Sendable, Equatable {
    public let agentRef: DeliveryAgentReference
    public let repository: String
    public let number: Int
    public let url: String
    public let title: String
    public let branch: String
    public let headOid: String
    public let localHeadOid: String
    public let state: String
    public let diffVersion: String
    public let localDiffEmpty: Bool
    public let checks: [DeliveryPullRequestCheck]
    public let observedAt: Date

    public var hasFailingChecks: Bool { checks.contains(where: \.isFailure) }
    var hasConclusiveChecks: Bool { !checks.isEmpty && checks.allSatisfy(\.isConclusive) }

    public init(agentRef: DeliveryAgentReference, repository: String, number: Int, url: String,
                title: String, branch: String, headOid: String, localHeadOid: String,
                state: String, diffVersion: String, localDiffEmpty: Bool,
                checks: [DeliveryPullRequestCheck], observedAt: Date) {
        self.agentRef = agentRef
        self.repository = repository
        self.number = number
        self.url = url
        self.title = title
        self.branch = branch
        self.headOid = headOid
        self.localHeadOid = localHeadOid
        self.state = state
        self.diffVersion = diffVersion
        self.localDiffEmpty = localDiffEmpty
        self.checks = checks
        self.observedAt = observedAt
    }
}

public struct DeliveryWorkflowSnapshot: Codable, Sendable, Equatable {
    public internal(set) var interventions: [DeliveryIntervention] = []
    public internal(set) var comments: [DeliveryComment] = []
    public internal(set) var metrics = DeliveryMetrics()
    public internal(set) var pullRequestLinks: [DeliveryPullRequestLink] = []
    var version = 1
    var observedAgents: [ObservedAgent] = []
    var lastTimestamp: Date?

    public init() {}

    struct ObservedAgent: Codable, Sendable, Equatable {
        let agentRef: DeliveryAgentReference
        var state: String
    }
}
