import Foundation
import Testing
@testable import TramaCore

@Suite(.serialized)
struct EngineSessionTests {
    private func fixture(_ body: String, timeout: TimeInterval = 10,
                         test: (OctoEngineClient, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("rpc fixture")
        let script = """
        #!/bin/sh
        [ "$#" = 3 ] && [ "$1" = '--request' ] && [ "$2" = '--home' ] || exit 8
        \(body)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = OctoEngineClient(executableURL: executable, homeURL: root, timeout: timeout, mutationTimeout: timeout)
        try await test(client, root)
    }

    @Test func startWritesLiteralJSONToStandardInput() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"agentId":42}}'
        """) { client, root in
            let task = "literal $HOME; $(echo hello)\nsecond line"
            let id = try await client.start(kind: "codex", cwd: "/tmp/a b", name: "example",
                                            task: task, session: "default", isolate: true)
            #expect(id == 42)
            let captured = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(captured.operation == "start")
            #expect(captured.task == task)
            #expect(captured.cwd == "/tmp/a b")
            #expect(captured.isolate == true)
            #expect(captured.confirmed == nil)
        }
    }

    @Test func listPreservesInterruptedStates() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' '{"protocol":1,"ok":true,"result":{"agents":[{"id":7,"name":"worker","kind":"codex","state":"lost","session":"default","cwd":"/tmp/project","project":"/tmp/project","task":"task","activity":"interrupted","branch":null,"nested":{"kind":"claude","pid":12,"cwd":null,"since_ms":123}}],"sessions":["default"]}}'
        """) { client, _ in
            let result = try await client.listSessions()
            #expect(result.agents.first?.state == "lost")
            #expect(result.agents.first?.isAlive == false)
            #expect(result.agents.first?.nested?.kind == "claude")
            #expect(result.agents.first?.nested?.sinceMs == 123)
            #expect(result.sessions == ["default"])
        }
    }

    @Test func inputPreservesControlBytesUsingBase64() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{}}'
        """) { client, root in
            let bytes = Data([0, 3, 13, 27, 91, 65, 255])
            try await client.sendInput(agentId: 2, data: bytes)
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "input")
            #expect(request.agentId == 2)
            #expect(Data(base64Encoded: request.input ?? "") == bytes)
        }
    }

    @Test func domainErrorIsPropagatedWithoutStderr() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' 'private detail' >&2
        printf '%s' '{"protocol":1,"ok":false,"error":"Sessão indisponível"}'
        """) { client, _ in
            await #expect(throws: EngineClientError.rejected("Sessão indisponível")) {
                try await client.stop(agentId: 7)
            }
        }
    }

    @Test func incompatibleRPCProtocolIsRejected() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' '{"protocol":2,"ok":true,"result":{}}'
        """) { client, _ in
            await #expect(throws: EngineClientError.incompatibleEngine) { try await client.stop(agentId: 7) }
        }
    }

    @Test func malformedSnapshotIsRejected() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' '{"protocol":1,"ok":true,"result":{"data":"not base64!","rows":24,"cols":80}}'
        """) { client, _ in
            await #expect(throws: EngineClientError.invalidResponse) { try await client.snapshot(agentId: 7) }
        }
    }

    @Test func largeRequestIsRejectedBeforeLaunching() async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.requestTooLarge) {
                try await client.start(kind: "codex", cwd: "/tmp", name: "example",
                                       task: String(repeating: "x", count: 70_000))
            }
        }
    }

    @Test func unreadInputCannotBlockTimeout() async throws {
        try await fixture("exec /bin/sleep 5", timeout: 0.1) { client, _ in
            let start = Date()
            await #expect(throws: EngineClientError.timedOut) {
                try await client.start(kind: "terminal", cwd: "/tmp", name: "example",
                                       task: String(repeating: "x", count: 60_000))
            }
            #expect(Date().timeIntervalSince(start) < 2)
        }
    }

    @Test func mergeIncludesExplicitConfirmation() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"message":"merged"}}'
        """) { client, root in
            #expect(try await client.merge(agentId: 9, message: "Reviewed change") == "merged")
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.confirmed == true)
            #expect(request.message == "Reviewed change")
        }
    }

    @Test func logsRetainTruncationMetadata() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' '{"protocol":1,"ok":true,"result":{"text":"recent output","truncated":true}}'
        """) { client, _ in
            let log = try await client.logs(agentId: 7)
            #expect(log.text == "recent output")
            #expect(log.truncated)
        }
    }


    @Test func usageRequiresExplicitConfirmationBeforeProcessLaunch() async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.invalidRequest) {
                try await client.usage(kind: "codex", confirmed: false)
            }
        }
    }

    @Test func usageDecodesLimitsAndTransmitsConfirmation() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"kind":"codex","limits":{"session":{"usedPercent":12.5,"resetsAtMs":1000},"weekly":null,"monthly":null,"credits":null},"problem":null,"updatedAtMs":900}}'
        """) { client, root in
            let usage = try await client.usage(kind: "codex", confirmed: true)
            #expect(usage.limits?.session?.usedPercent == 12.5)
            #expect(usage.limits?.session?.resetsAtMs == 1000)
            #expect(usage.problem == nil)
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "usage")
            #expect(request.confirmed == true)
            #expect(request.kind == "codex")
        }
    }

    @Test func removeRequiresConfirmationBeforeProcessLaunch() async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.invalidRequest) {
                try await client.remove(agentId: 7, confirmed: false)
            }
        }
    }

    @Test func removeTransmitsConfirmedRecordID() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{}}'
        """) { client, root in
            try await client.remove(agentId: 7, confirmed: true)
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "remove")
            #expect(request.agentId == 7)
            #expect(request.confirmed == true)
        }
    }

    @Test(arguments: [(1, 80), (101, 80), (24, 9), (24, 241)])
    func resizeRejectsOutOfContractBoundsBeforeLaunching(rows: Int, cols: Int) async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.invalidRequest) {
                try await client.resize(agentId: 7, rows: rows, cols: cols)
            }
        }
    }

    @Test func sessionEditsTransmitNamesAsLiteralJSON() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{}}'
        """) { client, root in
            try await client.renameSession(from: "default", to: "revisão")
            var request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "rename_session")
            #expect(request.session == "default")
            #expect(request.name == "revisão")
            try await client.moveAgent(agentId: 7, to: "revisão")
            request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "move_agent")
            #expect(request.agentId == 7)
            #expect(request.session == "revisão")
        }
    }

    @Test func newDestructiveOperationsRequireConfirmationBeforeLaunch() async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.invalidRequest) { try await client.archiveWorktree(agentId: 7, confirmed: false) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.applyLogRetention(planToken: "plan", confirmed: false) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.applyLogRetention(planToken: "", confirmed: true) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.exportLogs(agentId: 7, confirmed: false) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.exportLogs(agentId: 7, redactions: [""], confirmed: true) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.exportLogs(agentId: 7, redactions: Array(repeating: "x", count: 33), confirmed: true) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.exportLogs(agentId: 7, redactions: [String(repeating: "ç", count: 513)], confirmed: true) }
        }
    }

    @Test func archivePreservesWorktreeMetadata() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"agentId":7,"path":"/tmp/worktree","branch":"orkai/worker","archivedAtMs":123,"preservesChanges":true}}'
        """) { client, root in
            let archive = try await client.archiveWorktree(agentId: 7, confirmed: true)
            #expect(archive.path == "/tmp/worktree")
            #expect(archive.preservesChanges)
            #expect(archive.archivedAtMs == 123)
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "archive_worktree")
            #expect(request.confirmed == true)
        }
    }

    @Test func processTreeKeepsParentEdgesAndIncompleteObservation() async throws {
        try await fixture("""
        /bin/cat >/dev/null
        printf '%s' '{"protocol":1,"ok":true,"result":{"agentId":7,"rootPid":123,"nodes":[{"pid":123,"parentPid":null,"name":"sh","kind":null},{"pid":124,"parentPid":123,"name":"sleep","kind":null}],"complete":false,"limitations":["Local snapshot"],"observedAtMs":500}}'
        """) { client, _ in
            let tree = try await client.processTree(agentId: 7)
            #expect(!tree.complete)
            #expect(tree.nodes.last?.parentPid == tree.rootPid)
            #expect(tree.limitations == ["Local snapshot"])
        }
    }

    @Test func retentionValidatesPerFileThresholdsBeforeLaunching() async throws {
        try await fixture("exit 90") { client, _ in
            await #expect(throws: EngineClientError.invalidRequest) { try await client.logRetention() }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.logRetention(maxAgeDays: 0) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.logRetention(maxAgeDays: 3651) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.logRetention(maxFileBytes: 1_073_741_825) }
        }
    }

    @Test func retentionPreviewAndApplyUseExactReviewedToken() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"planToken":"reviewed-plan","candidates":[{"path":"agents/7/output.log","bytes":42}],"totalBytes":42,"maxAgeDays":30,"maxFileBytes":1024,"removedFiles":1,"removedBytes":42}}'
        """) { client, root in
            let preview = try await client.logRetention(maxAgeDays: 30, maxFileBytes: 1024)
            #expect(preview.totalBytes == 42)
            #expect(preview.candidates.first?.path == "agents/7/output.log")
            var request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "log_retention")
            #expect(request.maxFileBytes == 1024)
            #expect(request.maxAgeDays == 30)
            #expect(request.confirmed == nil)
            let applied = try await client.applyLogRetention(planToken: preview.planToken, confirmed: true)
            #expect(applied.removedFiles == 1)
            request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "apply_log_retention")
            #expect(request.planToken == "reviewed-plan")
            #expect(request.confirmed == true)
        }
    }

    @Test func exportPreservesExactPreviewAndReviewWarning() async throws {
        try await fixture("""
        /bin/cat > "$3/request.json"
        printf '%s' '{"protocol":1,"ok":true,"result":{"text":"Reviewed █ output\\n","truncated":true,"requiresSensitiveReview":true,"warning":"Review before saving"}}'
        """) { client, root in
            let preview = try await client.exportLogs(agentId: 7, redactions: ["segredo ç"], confirmed: true)
            #expect(preview.text == "Reviewed █ output\n")
            #expect(preview.truncated)
            #expect(preview.requiresSensitiveReview)
            #expect(preview.warning == "Review before saving")
            let request = try JSONDecoder().decode(EngineRequest.self,
                from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "export_logs")
            #expect(request.redactions == ["segredo ç"])
            #expect(request.confirmed == true)
        }
    }
}
