import Foundation
import Testing
@testable import TramaCore

@Suite(.serialized)
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
        #expect(result.operations.contains("inspect"))
        #expect(result.operations.contains("start"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"] != nil))
    func swiftControlsARealShellAcrossRequestProcesses() async throws {
        let enginePath = try #require(ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-swift-" + UUID().uuidString)
        let project = root.appendingPathComponent("project with spaces", isDirectory: true)
        let home = root.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let wrapper = root.appendingPathComponent("controlled engine")
        let quotedEngine = "'" + enginePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nexport SHELL=/bin/sh\nunset ENV BASH_ENV ZDOTDIR\nexec " + quotedEngine + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = OctoEngineClient(executableURL: wrapper, homeURL: home, timeout: 15)
        do {
            try await client.createSession(name: "swift-lifecycle")
            let id = try await client.start(kind: "terminal", cwd: project.path, name: "controlled-shell",
                                            task: "", session: "swift-lifecycle", isolate: false)
            let marker = "TRAMA_SWIFT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            // The complete marker does not occur in the echoed command, so only executed output matches.
            let suffix = String(marker.dropFirst("TRAMA_SWIFT_".count))
            let input = "printf 'TRAMA_SWIFT_%s\\n' " + suffix + "\r"
            try await client.sendInput(agentId: id, data: Data(input.utf8))
            let deadline = Date().addingTimeInterval(10)
            var sawOutput = false
            repeat {
                let snapshot = try await client.snapshot(agentId: id)
                let bytes = try #require(snapshot.bytes)
                if String(decoding: bytes, as: UTF8.self).contains(marker) {
                    sawOutput = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            } while Date() < deadline
            try #require(sawOutput, "The controlled shell did not emit the expected marker")

            try await client.resize(agentId: id, rows: 30, cols: 90)
            let resized = try await client.snapshot(agentId: id)
            #expect(resized.rows == 30)
            #expect(resized.cols == 90)

            // A fresh Swift client observes the holder started by an earlier request process.
            let reopened = OctoEngineClient(executableURL: wrapper, homeURL: home, timeout: 15)
            let running = try await reopened.listSessions()
            let agent = try #require(running.agents.first { $0.id == id })
            #expect(agent.isAlive)
            #expect(agent.kind == "terminal")
            #expect(agent.session == "swift-lifecycle")
            #expect(running.sessions.contains("swift-lifecycle"))

            try await reopened.stop(agentId: id)
            let stopped = try await reopened.listSessions()
            #expect(stopped.agents.first { $0.id == id }?.state == "exited")
            let log = try await reopened.logs(agentId: id)
            #expect(log.text.contains(marker))
            #expect(!log.truncated)
            try await reopened.renameSession(from: "swift-lifecycle", to: "swift-renamed")
            try await reopened.createSession(name: "swift-destination")
            try await reopened.moveAgent(agentId: id, to: "swift-destination")
            let moved = try await reopened.listSessions()
            #expect(moved.agents.first { $0.id == id }?.session == "swift-destination")
            #expect(!moved.sessions.contains("swift-lifecycle"))
            let tree = try await reopened.processTree(agentId: id)
            #expect(tree.nodes.isEmpty)
            #expect(!tree.complete)
            let preview = try await reopened.exportLogs(agentId: id, redactions: [marker], confirmed: true)
            #expect(!preview.text.contains(marker))
            #expect(preview.requiresSensitiveReview)
            let retention = try await reopened.logRetention(maxFileBytes: 0)
            #expect(!retention.candidates.isEmpty)
            let cleaned = try await reopened.applyLogRetention(planToken: retention.planToken, confirmed: true)
            #expect(cleaned.removedFiles == retention.candidates.count)
            let preserved = try await reopened.listSessions()
            #expect(preserved.agents.contains { $0.id == id })
            try await cleanUpControlledSessions(client: client, root: root)
        } catch {
            try? await cleanUpControlledSessions(client: client, root: root)
            throw error
        }
    }

    private func cleanUpControlledSessions(client: OctoEngineClient, root: URL) async throws {
        let sessions = try await client.listSessions()
        for agent in sessions.agents where agent.isAlive {
            try await client.stop(agentId: agent.id)
        }
        // Keep the fixture on cleanup failure so the holder's runtime data remains recoverable.
        try FileManager.default.removeItem(at: root)
    }

}
