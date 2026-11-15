/// Resolves a choice among destinations supplied by the caller. Project-local destinations
/// are revalidated and, when needed, materialized in the engine before an explicit start.
public struct EngineSessionSelection: Equatable, Sendable {
    public let options: [String]
    public let selectedSession: String?

    public init(sessions: [String], preferredSession: String?) {
        options = Array(Set(sessions.filter { !$0.isEmpty })).sorted()
        if let preferredSession, options.contains(preferredSession) {
            selectedSession = preferredSession
        } else {
            selectedSession = options.first
        }
    }
}
