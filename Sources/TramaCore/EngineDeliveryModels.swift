import Foundation

public struct EngineDiffSnapshot: Codable, Sendable, Equatable {
    public let version: String
    public let text: String
    public let headOid: String
    public let createdAtMs: UInt64

    public init(version: String, text: String, headOid: String, createdAtMs: UInt64) {
        self.version = version
        self.text = text
        self.headOid = headOid
        self.createdAtMs = createdAtMs
    }

    /// One-based lines in the complete diff. Only unified-hunk content accepts notes.
    /// Hunk counts preserve content beginning +++/--- without treating file headers as anchors.
    public var commentableLines: Set<Int> {
        func count(_ range: Substring, sign: Character) -> Int? {
            guard range.first == sign else { return nil }
            let parts = range.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), UInt(parts[0]) != nil else { return nil }
            return parts.count == 1 ? 1 : Int(parts[1]).flatMap { $0 >= 0 ? $0 : nil }
        }
        var old = 0
        var new = 0
        var result = Set<Int>()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("@@ ") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 3, let oldCount = count(fields[1], sign: "-"),
                   let newCount = count(fields[2], sign: "+") {
                    old = oldCount
                    new = newCount
                } else { old = 0; new = 0 }
            } else {
                switch line.first {
                case " " where old > 0 && new > 0:
                    old -= 1; new -= 1; result.insert(index + 1)
                case "-" where old > 0:
                    old -= 1; result.insert(index + 1)
                case "+" where new > 0:
                    new -= 1; result.insert(index + 1)
                case "\\": break
                default: old = 0; new = 0
                }
            }
        }
        return result
    }
}

public struct EngineReviewNote: Codable, Sendable, Equatable {
    public let line: Int
    public let body: String
    public init(line: Int, body: String) { self.line = line; self.body = body }
}

/// Show this exact text, then confirm the captured notes and token. A token is not authorization.
public struct EngineReviewPreview: Codable, Sendable, Equatable {
    public let text: String
    public let token: String
    public let version: String
    public let createdAtMs: UInt64
    public let noteCount: Int
    public init(text: String, token: String, version: String, createdAtMs: UInt64, noteCount: Int) {
        self.text = text; self.token = token; self.version = version
        self.createdAtMs = createdAtMs; self.noteCount = noteCount
    }
}

/// Transport acknowledgment only; it does not prove the provider executed or accepted the review.
public struct EngineReviewDelivery: Codable, Sendable, Equatable {
    public let agentId: UInt32
    public let createdAtMs: UInt64
    public let version: String
    public let noteCount: Int
    public let deliveredToPTY: Bool
    public init(agentId: UInt32, createdAtMs: UInt64, version: String, noteCount: Int, deliveredToPTY: Bool) {
        self.agentId = agentId; self.createdAtMs = createdAtMs; self.version = version
        self.noteCount = noteCount; self.deliveredToPTY = deliveredToPTY
    }
}

public struct EngineGitHubCheck: Codable, Sendable, Equatable {
    public let name: String
    public let state: String
    public let conclusion: String?
    public init(name: String, state: String, conclusion: String? = nil) {
        self.name = name; self.state = state; self.conclusion = conclusion
    }
}

/// A manual, point-in-time read. CI describes headOid, never uncommitted edits.
/// Compare diffVersion with the displayed snapshot, matchesLocalHead, and localDiffEmpty.
public struct EngineGitHubPR: Codable, Sendable, Equatable {
    public let number: Int
    public let url: String
    public let title: String
    public let state: String
    public let repository: String
    public let branch: String
    public let headOid: String
    public let localHeadOid: String
    public let matchesLocalHead: Bool
    /// True only when Git status has no staged, unstaged, or untracked changes.
    public let localDiffEmpty: Bool
    public let diffVersion: String
    public let checks: [EngineGitHubCheck]
    public let queriedAtMs: UInt64
    public init(number: Int, url: String, title: String, state: String, repository: String,
                branch: String, headOid: String, localHeadOid: String, matchesLocalHead: Bool,
                localDiffEmpty: Bool, diffVersion: String, checks: [EngineGitHubCheck], queriedAtMs: UInt64) {
        self.number = number; self.url = url; self.title = title; self.state = state
        self.repository = repository; self.branch = branch; self.headOid = headOid
        self.localHeadOid = localHeadOid; self.matchesLocalHead = matchesLocalHead
        self.localDiffEmpty = localDiffEmpty; self.diffVersion = diffVersion
        self.checks = checks; self.queriedAtMs = queriedAtMs
    }
}
