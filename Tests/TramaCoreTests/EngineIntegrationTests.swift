import Foundation
import Testing
@testable import TramaCore

struct EngineIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"] != nil))
    func swiftCommunicatesWithTheCompiledRustEngine() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = OctoEngineClient(executableURL: URL(fileURLWithPath: path), homeURL: root)
        let result = try await client.inspect()
        #expect(result.upstreamRevision == OctoEngineClient.supportedRevision)
        #expect(result.providers.contains { $0.id == "codex" })
        #expect(result.providers.contains { $0.id == "claude" })
        #expect(result.providers.count == 10)
        #expect(result.agentCount == 0)
        #expect(result.operations == ["inspect"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    }
}
