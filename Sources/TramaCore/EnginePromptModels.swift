import Foundation

/// Acknowledges transport to the existing PTY, not provider processing or success.
public struct EnginePromptDelivery: Codable, Sendable, Equatable {
    public let agentId: UInt32
    public let createdAtMs: UInt64
    public let deliveredToPTY: Bool

    public init(agentId: UInt32, createdAtMs: UInt64, deliveredToPTY: Bool) {
        self.agentId = agentId
        self.createdAtMs = createdAtMs
        self.deliveredToPTY = deliveredToPTY
    }
}
