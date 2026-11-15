import Foundation
import Darwin

/// Labels are separate from navigation preferences: closing tabs/resetting navigation cannot erase them.
public struct ProjectSessionRepository: Sendable {
    public let fileURL: URL
    private let writer: @Sendable (Data, URL) throws -> Void
    private static let maximumBytes = 256 * 1_024

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, writer: { try $0.write(to: $1, options: .atomic) })
    }

    init(fileURL: URL, writer: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.writer = writer
    }

    private struct Snapshot: Codable {
        let version: Int
        var sessions: [ProjectSession]
    }

    public func load() throws -> [ProjectSession] { try withLock { try read() } }

    /// Re-read under lock, preserving changes from other instances. Also used to label legacy sessions.
    public func save(_ entry: ProjectSession) throws -> [ProjectSession] {
        try withLock {
            var entries = try read()
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !entry.engineID.isEmpty, entry.engineID.utf8.count <= 128 else { throw RepositoryError.invalidName }
            guard !entries.contains(where: {
                $0.projectID == entry.projectID && $0.engineID != entry.engineID && $0.name == name
            }) else { throw RepositoryError.duplicateName }
            entries.removeAll { $0.projectID == entry.projectID && $0.engineID == entry.engineID }
            entries.append(ProjectSession(projectID: entry.projectID, engineID: entry.engineID, name: name, managed: entry.managed))
            let data = try JSONEncoder().encode(Snapshot(version: 1, sessions: entries))
            guard data.count <= Self.maximumBytes else { throw RepositoryError.invalidData }
            try writer(data, fileURL)
            return entries
        }
    }

    private func read() throws -> [ProjectSession] {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return [] }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw RepositoryError.invalidData }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else {
            throw RepositoryError.invalidData
        }
        var identities = Set<String>(), names = Set<String>()
        for entry in snapshot.sessions {
            guard !entry.engineID.isEmpty, entry.engineID.utf8.count <= 128,
                  !entry.name.isEmpty, entry.name.count <= 64,
                  entry.name == entry.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  !entry.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  identities.insert(entry.projectID.uuidString + "/" + entry.engineID).inserted,
                  names.insert(entry.projectID.uuidString + "/" + entry.name).inserted else { throw RepositoryError.invalidData }
        }
        return snapshot.sessions
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RepositoryError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public enum RepositoryError: LocalizedError {
        case invalidData, invalidName, duplicateName, busy
        public var errorDescription: String? {
            switch self {
            case .invalidData: "O catálogo de sessões está inválido e foi preservado."
            case .invalidName: "Use um nome de sessão entre 1 e 64 caracteres, sem caracteres de controle."
            case .duplicateName: "Já existe uma sessão com esse nome neste projeto."
            case .busy: "Outra instância está atualizando as sessões. Tente novamente."
            }
        }
    }
}
