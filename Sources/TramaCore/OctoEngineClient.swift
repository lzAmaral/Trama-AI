import Darwin
import Foundation

public struct EngineProvider: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let installed: Bool
}

public struct EngineInspection: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let engine: String
    public let upstreamRevision: String
    public let upstreamVersion: String
    public let providers: [EngineProvider]
    public let agentCount: Int
    public let operations: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case engine, upstreamRevision, upstreamVersion, providers, agentCount, operations
    }
}

public struct OctoEngineClient: Sendable {
    public static let supportedRevision = "f66aa854313026870aaf57f65d26d9cbfbf32269"
    public let executableURL: URL
    public let homeURL: URL
    public let timeout: TimeInterval
    public let mutationTimeout: TimeInterval

    public init(executableURL: URL, homeURL: URL, timeout: TimeInterval = 10, mutationTimeout: TimeInterval = 30) {
        self.executableURL = executableURL
        self.homeURL = homeURL
        self.timeout = timeout.isFinite ? min(30, max(0.05, timeout)) : 10
        self.mutationTimeout = mutationTimeout.isFinite ? min(30, max(0.05, mutationTimeout)) : 30
    }

    public static var defaultExecutableURL: URL {
        if let path = ProcessInfo.processInfo.environment["TRAMA_ENGINE_PATH"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return (Bundle.main.executableURL ?? Bundle.main.bundleURL)
            .deletingLastPathComponent().appendingPathComponent("trama-engine")
    }

    public static var defaultHomeURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Trama/Engine", isDirectory: true)
    }

    public func inspect() async throws -> EngineInspection {
        let data = try await execute(arguments: ["--inspect", "--home", homeURL.path],
                                     input: nil, timeout: timeout, outputLimit: 1_048_576)
        let inspection: EngineInspection
        do {
            inspection = try JSONDecoder().decode(EngineInspection.self, from: data)
        } catch {
            throw EngineClientError.invalidResponse
        }
        guard inspection.protocolVersion == 1,
              inspection.engine == "octo",
              inspection.upstreamRevision == Self.supportedRevision,
              inspection.agentCount >= 0,
              inspection.operations.contains("inspect"),
              Set(inspection.providers.map(\.id)).count == inspection.providers.count else {
            throw EngineClientError.incompatibleEngine
        }
        return inspection
    }

    public func listSessions() async throws -> EngineSessionList {
        try await rpc(EngineRequest(operation: "list"))
    }

    public func start(kind: String, cwd: String, name: String, task: String,
                      session: String = "default", isolate: Bool = false) async throws -> UInt32 {
        let result: Started = try await rpc(EngineRequest(operation: "start", kind: kind, cwd: cwd,
            name: name, task: task, session: session, isolate: isolate), longRunning: true)
        return result.agentId
    }

    /// Creates once and returns the exact identity acknowledged by that start request.
    public func startIdentified(kind: String, cwd: String, name: String, task: String,
                                session: String = "default", isolate: Bool = false) async throws -> DeliveryAgentReference {
        let result: Started = try await rpc(EngineRequest(operation: "start", kind: kind, cwd: cwd,
            name: name, task: task, session: session, isolate: isolate), longRunning: true)
        guard let createdAtMs = result.createdAtMs, createdAtMs > 0 else { throw EngineClientError.invalidResponse }
        return DeliveryAgentReference(id: result.agentId, createdAtMs: createdAtMs)
    }

    public func sendInput(agentId: UInt32, data: Data, createdAtMs: UInt64? = nil) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "input", agentId: agentId,
                                                    input: data.base64EncodedString(), createdAtMs: createdAtMs))
    }

    public func snapshot(agentId: UInt32) async throws -> EngineSnapshot {
        let result: EngineSnapshot = try await rpc(EngineRequest(operation: "snapshot", agentId: agentId))
        guard result.rows > 0, result.cols > 0, result.bytes != nil else { throw EngineClientError.invalidResponse }
        return result
    }

    public func resize(agentId: UInt32, rows: Int, cols: Int, createdAtMs: UInt64? = nil) async throws {
        guard (2...100).contains(rows), (10...240).contains(cols) else {
            throw EngineClientError.invalidRequest
        }
        let _: Empty = try await rpc(EngineRequest(operation: "resize", agentId: agentId, rows: rows, cols: cols, createdAtMs: createdAtMs))
    }

    public func stop(agentId: UInt32, createdAtMs: UInt64? = nil) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "stop", agentId: agentId, createdAtMs: createdAtMs), longRunning: true)
    }

    /// Removes only an exited record without a worktree after explicit user confirmation.
    public func remove(agentId: UInt32, confirmed: Bool, createdAtMs: UInt64? = nil) async throws {
        guard confirmed else { throw EngineClientError.invalidRequest }
        let _: Empty = try await rpc(EngineRequest(operation: "remove", agentId: agentId, confirmed: true, createdAtMs: createdAtMs))
    }

    public func resume(agentId: UInt32, createdAtMs: UInt64? = nil) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "resume", agentId: agentId, createdAtMs: createdAtMs), longRunning: true)
    }

    public func createSession(name: String) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "create_session", session: name))
    }

    public func renameSession(from: String, to: String) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "rename_session", name: to, session: from))
    }

    public func moveAgent(agentId: UInt32, to session: String, createdAtMs: UInt64? = nil) async throws {
        let _: Empty = try await rpc(EngineRequest(operation: "move_agent", agentId: agentId, session: session, createdAtMs: createdAtMs))
    }

    /// Requires confirmation that this archives in place and does not reclaim disk space.
    public func archiveWorktree(agentId: UInt32, confirmed: Bool, createdAtMs: UInt64? = nil) async throws -> EngineWorktreeArchive {
        guard confirmed else { throw EngineClientError.invalidRequest }
        return try await rpc(EngineRequest(operation: "archive_worktree", agentId: agentId, confirmed: true, createdAtMs: createdAtMs))
    }

    public func processTree(agentId: UInt32) async throws -> EngineProcessTree {
        try await rpc(EngineRequest(operation: "process_tree", agentId: agentId))
    }

    /// Preview only. Cleanup is manual and never applies to a running or interrupted holder.
    public func logRetention(maxAgeDays: UInt32? = nil, maxFileBytes: UInt64? = nil) async throws -> EngineLogRetentionPlan {
        guard maxAgeDays != nil || maxFileBytes != nil,
              maxAgeDays.map({ (1...3650).contains($0) }) ?? true,
              maxFileBytes.map({ $0 <= 1_073_741_824 }) ?? true else { throw EngineClientError.invalidRequest }
        return try await rpc(EngineRequest(operation: "log_retention", maxAgeDays: maxAgeDays, maxFileBytes: maxFileBytes))
    }

    /// Apply only the exact reviewed plan. The engine rejects a stale plan before deleting files.
    public func applyLogRetention(planToken: String, confirmed: Bool) async throws -> EngineLogRetentionResult {
        guard confirmed, !planToken.isEmpty else { throw EngineClientError.invalidRequest }
        return try await rpc(EngineRequest(operation: "apply_log_retention", confirmed: true, planToken: planToken))
    }

    /// Prepares a preview for sensitive-data review; confirmation does not imply complete sanitization.
    public func exportLogs(agentId: UInt32, redactions: [String] = [], confirmed: Bool) async throws -> EngineLogExport {
        guard confirmed, redactions.count <= 32,
              redactions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              redactions.reduce(0, { $0 + $1.utf8.count }) <= 8192 else { throw EngineClientError.invalidRequest }
        return try await rpc(EngineRequest(operation: "export_logs", agentId: agentId, confirmed: true, redactions: redactions))
    }

    public func skills(kind: String, cwd: String) async throws -> [EngineSkill] {
        let result: Skills = try await rpc(EngineRequest(operation: "skills", kind: kind, cwd: cwd))
        return result.skills
    }

    /// Only call after the user explicitly authorizes reading the selected provider's usage.
    public func usage(kind: String, confirmed: Bool) async throws -> EngineUsage {
        guard confirmed else { throw EngineClientError.invalidRequest }
        return try await rpc(EngineRequest(operation: "usage", kind: kind, confirmed: true),
                             requestTimeout: 45)
    }

    public func logs(agentId: UInt32) async throws -> EngineLog {
        try await rpc(EngineRequest(operation: "logs", agentId: agentId))
    }

    public func diff(agentId: UInt32) async throws -> String {
        let result: Diff = try await rpc(EngineRequest(operation: "diff", agentId: agentId))
        return result.text
    }

    public func diffSnapshot(agentId: UInt32) async throws -> EngineDiffSnapshot {
        let result: EngineDiffSnapshot = try await rpc(EngineRequest(operation: "diff_snapshot", agentId: agentId))
        guard Self.isDigest(result.version), Self.isOID(result.headOid), result.text.utf8.count <= 512_000 else {
            throw EngineClientError.invalidResponse
        }
        return result
    }

    /// Returns the exact batch to display before asking the user to confirm delivery.
    public func previewReview(agentId: UInt32, createdAtMs: UInt64, expectedVersion: String,
                              notes: [EngineReviewNote]) async throws -> EngineReviewPreview {
        try Self.validateReview(version: expectedVersion, notes: notes)
        let result: EngineReviewPreview = try await rpc(EngineRequest(operation: "review_preview", agentId: agentId,
            createdAtMs: createdAtMs, expectedVersion: expectedVersion, notes: notes))
        guard result.createdAtMs == createdAtMs, result.version == expectedVersion,
              result.noteCount == notes.count, Self.isDigest(result.token), !result.text.isEmpty,
              result.text.utf8.count + 13 <= 24_000 else { throw EngineClientError.invalidResponse }
        return result
    }

    /// Sends one confirmed batch, without retries. Acknowledgment proves transport delivery only.
    public func sendReview(agentId: UInt32, createdAtMs: UInt64, expectedVersion: String,
                           notes: [EngineReviewNote], reviewToken: String, confirmed: Bool) async throws -> EngineReviewDelivery {
        guard confirmed, Self.isDigest(reviewToken) else { throw EngineClientError.invalidRequest }
        try Self.validateReview(version: expectedVersion, notes: notes)
        let result: EngineReviewDelivery = try await rpc(EngineRequest(operation: "send_review", agentId: agentId,
            confirmed: true, createdAtMs: createdAtMs, expectedVersion: expectedVersion,
            reviewToken: reviewToken, notes: notes), longRunning: true)
        guard result.agentId == agentId, result.createdAtMs == createdAtMs, result.version == expectedVersion,
              result.noteCount == notes.count, result.deliveredToPTY else { throw EngineClientError.invalidResponse }
        return result
    }

    /// The user's send action confirms this text. Sends once to an existing AI prompt;
    /// acknowledgment proves transport delivery only. Never retries an uncertain result.
    public func sendPrompt(agentId: UInt32, createdAtMs: UInt64, text: String,
                           confirmed: Bool) async throws -> EnginePromptDelivery {
        guard confirmed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 24_000 - 13,
              !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
              }) else { throw EngineClientError.invalidRequest }
        let result: EnginePromptDelivery = try await rpc(EngineRequest(operation: "send_prompt", agentId: agentId,
            message: text, confirmed: true, createdAtMs: createdAtMs))
        guard result.agentId == agentId, result.createdAtMs == createdAtMs,
              result.deliveredToPTY else { throw EngineClientError.invalidResponse }
        return result
    }

    /// Manual read only. Explicit confirmation authorizes gh to access its credentials and github.com.
    public func githubPR(agentId: UInt32, createdAtMs: UInt64, number: Int? = nil, confirmed: Bool) async throws -> EngineGitHubPR {
        guard confirmed, number.map({ (1...Int(UInt32.max)).contains($0) }) ?? true else {
            throw EngineClientError.invalidRequest
        }
        let result: EngineGitHubPR = try await rpc(EngineRequest(operation: "github_pr", agentId: agentId,
            confirmed: true, createdAtMs: createdAtMs, number: number), requestTimeout: max(timeout, 20))
        guard result.number > 0, number.map({ $0 == result.number }) ?? true,
              Self.isOID(result.headOid), Self.isOID(result.localHeadOid), Self.isDigest(result.diffVersion),
              result.matchesLocalHead == (result.headOid == result.localHeadOid),
              result.url == "https://github.com/\(result.repository)/pull/\(result.number)",
              result.repository.split(separator: "/").count == 2, result.checks.count <= 100 else {
            throw EngineClientError.invalidResponse
        }
        return result
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isOID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func validateReview(version: String, notes: [EngineReviewNote]) throws {
        guard isDigest(version), (1...32).contains(notes.count),
              notes.allSatisfy({ note in
                  note.line > 0 && !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !note.body.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
              }), notes.reduce(0, { $0 + $1.body.utf8.count }) <= 24_000 else { throw EngineClientError.invalidRequest }
    }

    /// Caller must obtain explicit confirmation after showing the diff and target project.
    public func merge(agentId: UInt32, message: String, createdAtMs: UInt64? = nil) async throws -> String {
        let result: Message = try await rpc(EngineRequest(operation: "merge", agentId: agentId,
                                                          message: message, confirmed: true, createdAtMs: createdAtMs), longRunning: true)
        return result.message
    }

    private struct Empty: Decodable, Sendable {}
    private struct Started: Decodable, Sendable { let agentId: UInt32; let createdAtMs: UInt64? }
    private struct Skills: Decodable, Sendable { let skills: [EngineSkill] }
    private struct Diff: Decodable, Sendable { let text: String }
    private struct Message: Decodable, Sendable { let message: String }
    private struct Envelope<Result: Decodable & Sendable>: Decodable, Sendable {
        let protocolVersion: Int
        let ok: Bool
        let result: Result?
        let error: String?
        enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", ok, result, error }
    }

    private func rpc<Result: Decodable & Sendable>(_ request: EngineRequest,
                                                   longRunning: Bool = false, requestTimeout: TimeInterval? = nil) async throws -> Result {
        let input = try JSONEncoder().encode(request)
        guard input.count <= 65_536 else { throw EngineClientError.requestTooLarge }
        let data = try await execute(arguments: ["--request", "--home", homeURL.path], input: input,
                                     timeout: requestTimeout ?? (longRunning ? mutationTimeout : timeout), outputLimit: 4_194_304,
                                     cancelRequestGroup: ["diff_snapshot", "review_preview", "send_review", "github_pr"].contains(request.operation))
        let envelope: Envelope<Result>
        do { envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data) }
        catch { throw EngineClientError.invalidResponse }
        guard envelope.protocolVersion == 1 else { throw EngineClientError.incompatibleEngine }
        guard envelope.ok else {
            // Only the structured RPC error is surfaced; stderr never reaches the UI.
            throw EngineClientError.rejected(String((envelope.error ?? "Operação recusada pelo motor").prefix(500)))
        }
        guard let result = envelope.result else { throw EngineClientError.invalidResponse }
        return result
    }

    private func execute(arguments: [String], input: Data?, timeout: TimeInterval,
                         outputLimit: Int, cancelRequestGroup: Bool = false) async throws -> Data {
        let operation = EngineProcessOperation(executableURL: executableURL, homeURL: homeURL,
            arguments: arguments, input: input, timeout: timeout, outputLimit: outputLimit,
            cancelRequestGroup: cancelRequestGroup)
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { try operation.run() }.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return data
    }

}

public enum EngineClientError: LocalizedError, Equatable {
    case unavailable
    case invalidLocation
    case launchFailed
    case failed(Int32)
    case timedOut
    case responseTooLarge
    case invalidResponse
    case incompatibleEngine
    case readFailed
    case invalidRequest
    case requestTooLarge
    case writeFailed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Motor não encontrado. Compile o trama-engine ou configure TRAMA_ENGINE_PATH."
        case .invalidLocation: "O motor e sua pasta de dados devem usar caminhos locais absolutos."
        case .launchFailed: "Não foi possível iniciar o motor."
        case .failed(let code): "O motor encerrou a operação com código \(code)."
        case .timedOut: "A operação do motor excedeu o tempo limite. Atualize as sessões antes de tentar novamente; uma ação iniciada pode continuar em execução."
        case .responseTooLarge: "A resposta do motor excedeu o limite de tamanho."
        case .invalidResponse: "O motor retornou uma resposta inválida."
        case .incompatibleEngine: "A versão ou o protocolo do motor não é compatível com este Trama."
        case .readFailed: "Não foi possível ler a resposta do motor."
        case .invalidRequest: "A operação contém parâmetros inválidos."
        case .requestTooLarge: "A solicitação excede o limite de 64 KiB."
        case .writeFailed: "Não foi possível enviar a solicitação ao motor."
        case .rejected(let message): message
        }
    }
}

/// Process and pipe ownership is confined to run(). Only the cancellation flag crosses threads.
private final class EngineProcessOperation: @unchecked Sendable {
    private let executableURL: URL
    private let homeURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private let outputLimit: Int
    private let arguments: [String]
    private let input: Data?
    private let cancelRequestGroup: Bool

    init(executableURL: URL, homeURL: URL, arguments: [String], input: Data?, timeout: TimeInterval,
         outputLimit: Int, cancelRequestGroup: Bool) {
        self.executableURL = executableURL
        self.homeURL = homeURL
        self.arguments = arguments
        self.input = input
        self.cancelRequestGroup = cancelRequestGroup
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func run() throws -> Data {
        try checkCancellation()
        guard executableURL.isFileURL, homeURL.isFileURL,
              executableURL.path.hasPrefix("/"), homeURL.path.hasPrefix("/") else {
            throw EngineClientError.invalidLocation
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw EngineClientError.unavailable
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let stdin = input == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdin?.fileHandleForReading ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        defer {
            try? stdin?.fileHandleForReading.close()
            try? stdin?.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
        }
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw EngineClientError.readFailed
            }
        }
        if let writer = stdin?.fileHandleForWriting {
            let flags = fcntl(writer.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(writer.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
                  fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw EngineClientError.writeFailed }
        }
        do { try process.run() } catch { throw EngineClientError.launchFailed }
        try? stdin?.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        var stdout = Data()
        var stderrCount = 0
        var inputOffset = 0
        var inputClosed = stdin == nil
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            repeat {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw EngineClientError.timedOut }
                if !inputClosed, let input, let writer = stdin?.fileHandleForWriting {
                    try writeInput(input, offset: &inputOffset, to: writer)
                    if inputOffset == input.count {
                        try? writer.close()
                        inputClosed = true
                    }
                }
                try drain(output.fileHandleForReading, capture: &stdout, count: nil)
                var discarded = Data()
                try drain(errors.fileHandleForReading, capture: &discarded, count: &stderrCount)
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while true
            process.waitUntilExit()
            // The child has exited; consume final available bytes without waiting for inherited pipes.
            try drain(output.fileHandleForReading, capture: &stdout, count: nil)
            var discarded = Data()
            try drain(errors.fileHandleForReading, capture: &discarded, count: &stderrCount)
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw EngineClientError.failed(process.terminationStatus)
            }
            return stdout
        } catch {
            if process.isRunning {
                // Only the new sidecar operations establish a private group. Prove its ownership
                // before killing it; existing holder processes and the app group are never targets.
                if cancelRequestGroup, Darwin.getpgid(process.processIdentifier) == process.processIdentifier {
                    // SIGTERM lets the sidecar kill its isolated command group, including helpers.
                    _ = Darwin.kill(-process.processIdentifier, SIGTERM)
                    Thread.sleep(forTimeInterval: 0.03)
                    if process.isRunning, Darwin.getpgid(process.processIdentifier) == process.processIdentifier {
                        _ = Darwin.kill(-process.processIdentifier, SIGKILL)
                    }
                }
                // Kill only the request process. A holder started by a mutation may persist; never retry automatically.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw error
        }
    }

    private func writeInput(_ data: Data, offset: inout Int, to handle: FileHandle) throws {
        guard offset < data.count else { return }
        let sent = data.withUnsafeBytes { buffer in
            Darwin.write(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if sent < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            throw EngineClientError.writeFailed
        }
        offset += sent
    }

    private func drain(_ handle: FileHandle, capture: inout Data, count: UnsafeMutablePointer<Int>?) throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<64 {
            let received = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if received == 0 { return }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw EngineClientError.readFailed
            }
            if let count {
                count.pointee += received
                guard count.pointee <= outputLimit else { throw EngineClientError.responseTooLarge }
            } else {
                guard capture.count + received <= outputLimit else { throw EngineClientError.responseTooLarge }
                capture.append(contentsOf: buffer.prefix(received))
            }
        }
    }
}
