import Foundation
import Darwin
import Testing
@testable import TramaCore

@Suite(.serialized)
struct EngineDeliveryTests {
    private let version = String(repeating: "a", count: 64)
    private let head = String(repeating: "b", count: 40)
    private let token = String(repeating: "c", count: 64)

    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func fixture(_ response: String, body: (OctoEngineClient, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-delivery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture engine")
        let script = "#!/bin/sh\n/bin/cat > " + quote(root.appendingPathComponent("request.json").path) + "\nprintf '%s' " + quote(response) + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await body(OctoEngineClient(executableURL: executable, homeURL: root.appendingPathComponent("home")), root)
    }
    private func envelope<T: Encodable>(_ value: T) throws -> String {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["protocol": 1, "ok": true, "result": value]), as: UTF8.self)
    }
    private func request(_ root: URL) throws -> EngineRequest {
        try JSONDecoder().decode(EngineRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
    }

    @Test func oldAgentRecordsDecodeWithoutIdentityTimestamp() throws {
        let data = Data(#"{"id":1,"name":"a","kind":"codex","state":"idle","session":"default","cwd":"/tmp","project":"/tmp","task":"","activity":""}"#.utf8)
        let agent = try JSONDecoder().decode(EngineAgent.self, from: data)
        #expect(agent.createdAtMs == nil)
    }

    @Test func hunkAnchorsHaveIdenticalOneBasedSemanticsIncludingHeaderLikeContent() {
        // The Rust integration vector exercises the same text and line set.
        let text = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1,2 +1,2 @@\n--- old source\n+++ new source\n unchanged\n\\ No newline at end of file\n@@ -4,0 +5 @@\n+added\nnot a hunk\n+outside\n"
        let snapshot = EngineDiffSnapshot(version: version, text: text, headOid: head, createdAtMs: 1)
        #expect(snapshot.commentableLines == [5, 6, 7, 10])
        let empty = EngineDiffSnapshot(version: version, text: "--- a\n+++ b\n@@ broken @@\n+outside\n", headOid: head, createdAtMs: 1)
        #expect(empty.commentableLines.isEmpty)
    }

    @Test func snapshotAndExactPreviewDecodeAndSerializeIdentityNotes() async throws {
        let snapshot = EngineDiffSnapshot(version: version, text: "@@ -1 +1 @@\n-old\n+new\n", headOid: head, createdAtMs: 77)
        try await fixture(envelope(snapshot)) { (client, root) async throws in
            #expect(try await client.diffSnapshot(agentId: 4) == snapshot)
            #expect(try request(root).operation == "diff_snapshot")
        }
        let notes = [EngineReviewNote(line: 3, body: "Please keep it.\nAlso test Unicode: ç.")]
        let preview = EngineReviewPreview(text: "Exact Rust formatter output\n", token: token, version: version, createdAtMs: 77, noteCount: 1)
        try await fixture(envelope(preview)) { (client, root) async throws in
            #expect(try await client.previewReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: notes) == preview)
            let encoded = try request(root)
            #expect(encoded.operation == "review_preview")
            #expect(encoded.createdAtMs == 77)
            #expect(encoded.expectedVersion == version)
            #expect(encoded.notes == notes)
            #expect(encoded.confirmed == nil)
        }
    }

    @Test func deliveryRequiresConfirmationAndKeepsTheCapturedBatchAndToken() async throws {
        let notes = [EngineReviewNote(line: 3, body: "A note")]
        let ack = EngineReviewDelivery(agentId: 4, createdAtMs: 77, version: version, noteCount: 1, deliveredToPTY: true)
        try await fixture(envelope(ack)) { (client, root) async throws in
            await #expect(throws: EngineClientError.invalidRequest) {
                try await client.sendReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: notes, reviewToken: token, confirmed: false)
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request.json").path))
            #expect(try await client.sendReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: notes, reviewToken: token, confirmed: true) == ack)
            let encoded = try request(root)
            #expect(encoded.reviewToken == token && encoded.notes == notes && encoded.confirmed == true)
        }
    }

    @Test func localValidationRejectsInvalidAnchorsControlsCountsAndBytesBeforeLaunching() async throws {
        try await fixture("unused") { (client, root) async throws in
            for notes in [[], [EngineReviewNote(line: 0, body: "invalid")], [EngineReviewNote(line: 1, body: "\u{1b}[201~\r")],
                          [EngineReviewNote(line: 1, body: "  ")], Array(repeating: EngineReviewNote(line: 1, body: "note"), count: 33),
                          [EngineReviewNote(line: 1, body: String(repeating: "ç", count: 12_001))]] {
                await #expect(throws: EngineClientError.invalidRequest) {
                    try await client.previewReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: notes)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request.json").path))
        }
    }

    @Test func staleAndInconsistentResponsesAreRejectedWithoutRetry() async throws {
        let bad = EngineReviewPreview(text: "preview", token: token, version: version, createdAtMs: 78, noteCount: 1)
        try await fixture(envelope(bad)) { (client, _) async throws in
            await #expect(throws: EngineClientError.invalidResponse) {
                try await client.previewReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: [EngineReviewNote(line: 1, body: "note")])
            }
        }
        try await fixture(#"{"protocol":1,"ok":false,"error":"review is obsolete; refresh the diff"}"#) { (client, _) async throws in
            await #expect(throws: EngineClientError.rejected("review is obsolete; refresh the diff")) {
                try await client.sendReview(agentId: 4, createdAtMs: 77, expectedVersion: version, notes: [EngineReviewNote(line: 1, body: "note")], reviewToken: token, confirmed: true)
            }
        }
    }

    @Test func githubIsExplicitAndPreservesCommitAndWorkingTreeEvidence() async throws {
        let pr = EngineGitHubPR(number: 7, url: "https://github.com/fixture/repository/pull/7", title: "PR", state: "OPEN", repository: "fixture/repository", branch: "main", headOid: head, localHeadOid: head, matchesLocalHead: true, localDiffEmpty: false, diffVersion: version, checks: [EngineGitHubCheck(name: "unit", state: "COMPLETED", conclusion: "FAILURE")], queriedAtMs: 99)
        try await fixture(envelope(pr)) { (client, root) async throws in
            await #expect(throws: EngineClientError.invalidRequest) { try await client.githubPR(agentId: 4, createdAtMs: 77, confirmed: false) }
            await #expect(throws: EngineClientError.invalidRequest) { try await client.githubPR(agentId: 4, createdAtMs: 77, number: 0, confirmed: true) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request.json").path))
            let result = try await client.githubPR(agentId: 4, createdAtMs: 77, number: 7, confirmed: true)
            #expect(result == pr && !result.localDiffEmpty)
            let encoded = try request(root)
            #expect(encoded.operation == "github_pr" && encoded.number == 7 && encoded.confirmed == true)
        }
    }

    @Test func existingMutationsForwardTheCapturedIdentityTimestamp() async throws {
        let response = #"{"protocol":1,"ok":true,"result":{"message":"Merged","agentId":4,"path":"/fixture","branch":"main","archivedAtMs":1,"preservesChanges":true}}"#
        try await fixture(response) { (client, root) async throws in
            try await client.sendInput(agentId: 4, data: Data("input".utf8), createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            try await client.resize(agentId: 4, rows: 40, cols: 120, createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            try await client.stop(agentId: 4, createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            try await client.resume(agentId: 4, createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            try await client.remove(agentId: 4, confirmed: true, createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            try await client.moveAgent(agentId: 4, to: "default", createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            _ = try await client.archiveWorktree(agentId: 4, confirmed: true, createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
            _ = try await client.merge(agentId: 4, message: "reviewed", createdAtMs: 77)
            #expect(try request(root).createdAtMs == 77)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"] != nil))
    func compiledEngineReviewAndCancellationLeaveTheHolderAlive() async throws {
        let engine = try #require(ProcessInfo.processInfo.environment["TRAMA_TEST_ENGINE_PATH"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-delivery-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", project.path] + args
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Controlled Test"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["remote", "add", "origin", "https://github.com/fixture/repository.git"])
        try Data("original\n".utf8).write(to: project.appendingPathComponent("file"))
        try git(["add", "."]); try git(["commit", "-m", "initial"])
        let pidFile = root.appendingPathComponent("gh.pid")
        let gh = bin.appendingPathComponent("gh")
        try Data(("#!/bin/sh\nprintf '%s' $$ > " + quote(pidFile.path) + "\nexec /bin/sleep 30\n").utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let wrapper = root.appendingPathComponent("engine")
        try Data(("#!/bin/sh\nexport SHELL=/bin/sh\nexport PATH=" + quote(bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin") + "\nunset ENV BASH_ENV\nexec " + quote(engine) + " \"$@\"\n").utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = OctoEngineClient(executableURL: wrapper, homeURL: root.appendingPathComponent("home"))
        let id = try await client.start(kind: "terminal", cwd: project.path, name: "controlled", task: "")
        do {
            try Data("modified\n".utf8).write(to: project.appendingPathComponent("file"))
            let snapshot = try await client.diffSnapshot(agentId: id)
            let line = try #require(snapshot.text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex(of: "+modified")) + 1
            #expect(snapshot.commentableLines.contains(line))
            let notes = [EngineReviewNote(line: line, body: "Please review this change.")]
            let preview = try await client.previewReview(agentId: id, createdAtMs: snapshot.createdAtMs, expectedVersion: snapshot.version, notes: notes)
            #expect(preview.text.contains("Please review this change."))
            let query = Task { try await client.githubPR(agentId: id, createdAtMs: snapshot.createdAtMs, confirmed: true) }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            query.cancel()
            await #expect(throws: CancellationError.self) { try await query.value }
            let childDeadline = Date().addingTimeInterval(2)
            while Darwin.kill(pid, 0) == 0, Date() < childDeadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(Darwin.kill(pid, 0) == -1)
            let listing = try await client.listSessions()
            #expect(listing.agents.first { $0.id == id }?.isAlive == true)
            try await client.stop(agentId: id)
        } catch { try? await client.stop(agentId: id); throw error }
    }
}
