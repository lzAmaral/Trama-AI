import Foundation

/// Local project metadata only. A malformed store is reported, never treated as empty.
public struct ProjectRepository: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Trama", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    public func load() throws -> [Project] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1 else {
            throw RepositoryError.unsupportedVersion(snapshot.version)
        }
        return snapshot.projects
    }

    public func save(_ projects: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Snapshot(version: 1, projects: projects))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private struct Snapshot: Codable {
        let version: Int
        let projects: [Project]
    }

    public enum RepositoryError: LocalizedError {
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "O arquivo de projetos usa a versão \(version), ainda não suportada por este Trama."
            }
        }
    }
}
