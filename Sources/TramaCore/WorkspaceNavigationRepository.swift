import Foundation
import Darwin

/// Bounded, versioned preferences containing only identities and presentation choices.
/// All operations coordinate on a stable lock inode; mutations re-read before applying intent.
public struct WorkspaceNavigationRepository: Sendable {
    public static let maximumFileBytes = 32 * 1_024
    public let fileURL: URL
    private let writer: @Sendable (Data, URL) throws -> Void

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Trama", isDirectory: true)
            .appendingPathComponent("workspace-navigation.json")
    }

    public init(fileURL: URL = Self.defaultFileURL) {
        self.init(fileURL: fileURL, writer: { try $0.write(to: $1, options: .atomic) })
    }

    // Fault injection shares the real lock/read/validate transaction path.
    init(fileURL: URL, writer: @escaping @Sendable (Data, URL) throws -> Void) {
        self.fileURL = fileURL
        self.writer = writer
    }

    public func load() throws -> WorkspaceNavigationState {
        try withLock { try read() }
    }

    /// Publish the returned state only after success. Errors preserve the on-disk preferences.
    /// Apply user intent here rather than copying a stale UI snapshot over another instance.
    @discardableResult
    public func update(_ body: (inout WorkspaceNavigationState) throws -> Void) throws -> WorkspaceNavigationState {
        try withLock {
            var state = try read()
            let before = state
            try body(&state)
            try state.validate()
            if state != before { try write(state) }
            return state
        }
    }

    /// User-requested reset only. Preserve the previous bytes in a uniquely named sibling
    /// before replacing them; backup or write failures are surfaced and never bypassed.
    @discardableResult
    public func reset() throws -> WorkspaceNavigationState {
        try withLock {
            do {
                try FileManager.default.copyItem(at: fileURL, to: fileURL.deletingLastPathComponent()
                    .appendingPathComponent(fileURL.lastPathComponent + ".backup-" + UUID().uuidString))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // A first-run reset has no previous preferences to preserve.
            }
            let state = WorkspaceNavigationState()
            try write(state)
            return state
        }
    }

    private struct Version: Decodable { let version: Int }
    private struct Snapshot: Codable {
        let version: Int
        let state: WorkspaceNavigationState
    }

    private func read() throws -> WorkspaceNavigationState {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return WorkspaceNavigationState()
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw RepositoryError.limitExceeded }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).version
            guard version == 1 else { throw RepositoryError.unsupportedVersion(version) }
            return try decoder.decode(Snapshot.self, from: data).state
        } catch let error as RepositoryError {
            throw error
        } catch {
            throw RepositoryError.invalidData
        }
    }

    private func write(_ state: WorkspaceNavigationState) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(version: 1, state: state))
        guard data.count <= Self.maximumFileBytes else { throw RepositoryError.limitExceeded }
        try writer(data, fileURL)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw RepositoryError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    public enum RepositoryError: LocalizedError, Equatable {
        case busy, invalidData, limitExceeded
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .busy: "Outra instância está atualizando a navegação. Tente novamente."
            case .invalidData: "As preferências de navegação contêm dados inválidos e foram preservadas."
            case .limitExceeded: "As preferências de navegação excedem o limite de armazenamento e foram preservadas."
            case .unsupportedVersion(let version): "A versão \(version) das preferências de navegação ainda não é suportada."
            }
        }
    }
}
