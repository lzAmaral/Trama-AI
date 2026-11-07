import Foundation

/// Generates a display name only; the original task is always sent unchanged.
enum AgentTaskName {
    static func make(task: String, existingNames: [String] = []) -> String {
        let folded = task.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let joined = words.prefix(6).joined(separator: "-")
        let prefix = String(String.UnicodeScalarView(joined.unicodeScalars.prefix(31)))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = prefix.isEmpty ? "tarefa" : prefix
        let existing = Set(existingNames.map { $0.lowercased() })
        // Upstream accepts at most 40 Unicode scalars. A fresh suffix also distinguishes
        // back-to-back creations before the latest engine snapshot arrives.
        var candidate: String
        repeat {
            candidate = stem + "-" + UUID().uuidString.prefix(8).lowercased()
        } while existing.contains(candidate)
        return candidate
    }
}
