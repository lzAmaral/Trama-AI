import Foundation
import Testing
@testable import TramaCore

struct OctoEngineClientTests {
    private let response = #"{"protocol":1,"engine":"octo","upstreamRevision":"f66aa854313026870aaf57f65d26d9cbfbf32269","upstreamVersion":"0.2.19","providers":[{"id":"claude","installed":true}],"agentCount":0,"operations":["inspect"]}"#

    private func withFixture(_ script: String, timeout: TimeInterval = 2,
                             body: (OctoEngineClient) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture engine")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = OctoEngineClient(executableURL: executable,
                                      homeURL: root.appendingPathComponent("home with spaces;literal"), timeout: timeout)
        try await body(client)
    }

    @Test func decodesInspectionAndPassesLiteralArguments() async throws {
        let script = """
        [ "$#" = 3 ] || exit 9
        [ "$1" = '--inspect' ] || exit 10
        [ "$2" = '--home' ] || exit 11
        case "$3" in *'home with spaces;literal') ;; *) exit 12 ;; esac
        printf '%s' '\(response)'
        """
        try await withFixture(script) { client in
            let result = try await client.inspect()
            #expect(result.protocolVersion == 1)
            #expect(result.providers.first?.id == "claude")
            #expect(result.providers.first?.installed == true)
            #expect(result.agentCount == 0)
        }
    }

    @Test func malformedJSONIsReported() async throws {
        try await withFixture("printf '%s' 'invalid'") { client in
            await #expect(throws: EngineClientError.invalidResponse) { try await client.inspect() }
        }
    }

    @Test func nonzeroExitDoesNotExposeStderr() async throws {
        try await withFixture("printf '%s' 'SECRET_TOKEN' >&2; exit 7") { client in
            do {
                _ = try await client.inspect()
                Issue.record("Expected an unsuccessful exit")
            } catch {
                #expect(error as? EngineClientError == .failed(7))
                #expect(!error.localizedDescription.contains("SECRET_TOKEN"))
            }
        }
    }

    @Test func incompatibleProtocolAndRevisionAreRejected() async throws {
        for invalid in [response.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2"),
                        response.replacingOccurrences(of: OctoEngineClient.supportedRevision, with: "unknown")] {
            try await withFixture("printf '%s' '\(invalid)'") { client in
                await #expect(throws: EngineClientError.incompatibleEngine) { try await client.inspect() }
            }
        }
    }

    @Test func missingExecutableIsReported() async {
        let client = OctoEngineClient(executableURL: URL(fileURLWithPath: "/nonexistent/\(UUID())"),
                                      homeURL: FileManager.default.temporaryDirectory)
        await #expect(throws: EngineClientError.unavailable) { try await client.inspect() }
    }

    @Test func hungInspectionIsTerminated() async throws {
        try await withFixture("exec /bin/sleep 5", timeout: 0.1) { client in
            let start = Date()
            await #expect(throws: EngineClientError.timedOut) { try await client.inspect() }
            #expect(Date().timeIntervalSince(start) < 2)
        }
    }

    @Test func cancellationStopsInspection() async throws {
        try await withFixture("exec /bin/sleep 5") { client in
            let task = Task { try await client.inspect() }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test func oversizedOutputIsRejected() async throws {
        try await withFixture("exec /usr/bin/yes x") { client in
            await #expect(throws: EngineClientError.responseTooLarge) { try await client.inspect() }
        }
    }
}
