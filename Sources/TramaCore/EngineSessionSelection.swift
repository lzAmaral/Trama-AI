/// A new task can only target a grouping present in the latest engine snapshot.
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
