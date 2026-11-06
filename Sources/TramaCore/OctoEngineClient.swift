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

    public init(executableURL: URL, homeURL: URL, timeout: TimeInterval = 10) {
        self.executableURL = executableURL
        self.homeURL = homeURL
        self.timeout = timeout.isFinite ? min(10, max(0.05, timeout)) : 10
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
        let operation = EngineProcessOperation(executableURL: executableURL, homeURL: homeURL, timeout: timeout)
        let data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { try operation.run() }.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
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

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Motor não encontrado. Compile o trama-engine ou configure TRAMA_ENGINE_PATH."
        case .invalidLocation: "O motor e sua pasta de dados devem usar caminhos locais absolutos."
        case .launchFailed: "Não foi possível iniciar a inspeção do motor."
        case .failed(let code): "O motor encerrou a inspeção com código \(code)."
        case .timedOut: "A inspeção do motor excedeu o tempo limite."
        case .responseTooLarge: "A resposta do motor excedeu o limite de tamanho."
        case .invalidResponse: "O motor retornou uma resposta inválida."
        case .incompatibleEngine: "A versão ou o protocolo do motor não é compatível com este Trama."
        case .readFailed: "Não foi possível ler a resposta do motor."
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
    private let outputLimit = 1_048_576

    init(executableURL: URL, homeURL: URL, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.homeURL = homeURL
        self.timeout = timeout
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
        process.executableURL = executableURL
        process.arguments = ["--inspect", "--home", homeURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        defer {
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
        do { try process.run() } catch { throw EngineClientError.launchFailed }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        var stdout = Data()
        var stderrCount = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            repeat {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw EngineClientError.timedOut }
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
                // This one-shot inspection owns no child agents. Kill only our direct child.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw error
        }
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
