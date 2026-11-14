import Foundation
import Darwin

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

    /// Re-reads persisted projects while holding a cross-process lock, so callers
    /// never overwrite another instance's registration with a stale UI snapshot.
    public func register(_ directory: URL) throws -> (project: Project, projects: [Project]) {
        try withExclusiveLock {
            var projects = try load()
            let project = try ProjectRegistration.project(for: directory, existing: projects)
            if !projects.contains(where: { $0.id == project.id }) {
                projects.append(project)
                try write(projects)
            }
            return (project, projects)
        }
    }

    /// Replaces the entire snapshot. Use register(_:) for additive UI operations.
    public func save(_ projects: [Project]) throws {
        try withExclusiveLock { try write(projects) }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Keep a stable sidecar inode: the JSON file itself is replaced atomically.
        let descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw RepositoryError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func write(_ projects: [Project]) throws {
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
        case busy

        public var errorDescription: String? {
            switch self {
            case .busy:
                "Outra instância do Trama está atualizando os projetos. Tente novamente."
            case .unsupportedVersion(let version):
                "O arquivo de projetos usa a versão \(version), ainda não suportada por este Trama."
            }
        }
    }
}
