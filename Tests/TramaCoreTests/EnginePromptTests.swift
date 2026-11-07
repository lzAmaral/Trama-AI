import Foundation
import Testing
@testable import TramaCore

struct EnginePromptTests {
    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func fixture(_ response: String, body: (OctoEngineClient, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-prompt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("controlled engine")
        let script = "#!/bin/sh\n/bin/cat > " + quote(root.appendingPathComponent("request.json").path) +
            "\nprintf x >> " + quote(root.appendingPathComponent("launches").path) + "\nprintf '%s' " + quote(response) + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await body(OctoEngineClient(executableURL: executable, homeURL: root.appendingPathComponent("home")), root)
    }

    private let ack = #"{"protocol":1,"ok":true,"result":{"agentId":4,"createdAtMs":77,"deliveredToPTY":true}}"#

    @Test func promptPreservesExactTextAndIdentityWithoutReviewFieldsOrRetry() async throws {
        try await fixture(ack) { (client, root) async throws in
            let text = "Olá 👨‍👩‍👧‍👦 می‌روم\n\tliteral $(touch nope); `echo nope`"
            let result = try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: text, confirmed: true)
            #expect(result == EnginePromptDelivery(agentId: 4, createdAtMs: 77, deliveredToPTY: true))
            let bytes = try Data(contentsOf: root.appendingPathComponent("request.json"))
            let request = try JSONDecoder().decode(EngineRequest.self, from: bytes)
            #expect(request.operation == "send_prompt")
            #expect(request.agentId == 4 && request.createdAtMs == 77)
            #expect(request.message == text && request.confirmed == true)
            #expect(Data(try #require(request.message).utf8) == Data(text.utf8))
            let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(Set(fields.keys) == ["operation", "agentId", "createdAtMs", "message", "confirmed"])
            #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
        }
    }

    @Test func confirmationControlsEmptyAndByteBoundsFailBeforeProcessLaunch() async throws {
        try await fixture(ack) { (client, root) async throws in
            await #expect(throws: EngineClientError.invalidRequest) {
                try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: "valid", confirmed: false)
            }
            for text in ["", " \n\t", "a\r", "\u{1b}[201~", "a\0b", "a\u{3}b", "a\u{7f}b", "a\u{85}b",
                         String(repeating: "x", count: 23_988), String(repeating: "ç", count: 11_994)] {
                await #expect(throws: EngineClientError.invalidRequest) {
                    try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: text, confirmed: true)
                }
            }
            for value in Array(0...31) + Array(127...159) where value != 9 && value != 10 {
                let control = String(try #require(UnicodeScalar(value)))
                await #expect(throws: EngineClientError.invalidRequest) {
                    try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: "a" + control + "b", confirmed: true)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("launches").path))
            let boundary = String(repeating: "ç", count: 11_993) + "x"
            #expect(boundary.utf8.count + 13 == 24_000)
            _ = try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: boundary, confirmed: true)
        }
    }

    @Test func inconsistentOrIncompleteAcknowledgmentsFailWithoutRetry() async throws {
        for result in [
            #"{"agentId":5,"createdAtMs":77,"deliveredToPTY":true}"#,
            #"{"agentId":4,"createdAtMs":78,"deliveredToPTY":true}"#,
            #"{"agentId":4,"createdAtMs":77,"deliveredToPTY":false}"#,
            #"{"agentId":4,"deliveredToPTY":true}"#,
            #"{"agentId":4,"createdAtMs":77}"#,
            #"{"agentId":4,"createdAtMs":-1,"deliveredToPTY":true}"#
        ] {
            try await fixture("{\"protocol\":1,\"ok\":true,\"result\":" + result + "}") { (client, root) async throws in
                await #expect(throws: EngineClientError.invalidResponse) {
                    try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: "hello", confirmed: true)
                }
                #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
            }
        }
    }

    @Test func olderEnginesAndRejectionRemainExplicitAndDoNotRetry() async throws {
        try await fixture(#"{"protocol":1,"ok":false,"error":"unsupported operation"}"#) { (client, root) async throws in
            await #expect(throws: EngineClientError.rejected("unsupported operation")) {
                try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: "hello", confirmed: true)
            }
            #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
        }
        try await fixture(#"{"protocol":2,"ok":true,"result":{"agentId":4,"createdAtMs":77,"deliveredToPTY":true}}"#) { (client, _) async throws in
            await #expect(throws: EngineClientError.incompatibleEngine) {
                try await client.sendPrompt(agentId: 4, createdAtMs: 77, text: "hello", confirmed: true)
            }
        }
        let legacy = try JSONDecoder().decode(EngineRequest.self, from: Data(#"{"operation":"list"}"#.utf8))
        #expect(legacy.message == nil && legacy.createdAtMs == nil)
    }

    @Test func identifiedStartUsesOneCreationAndLegacyStartRemainsCompatible() async throws {
        try await fixture(#"{"protocol":1,"ok":true,"result":{"agentId":4,"createdAtMs":77}}"#) { (client, root) async throws in
            let reference = try await client.startIdentified(kind: "codex", cwd: "/fixture", name: "new", task: "task", session: "session", isolate: true)
            #expect(reference == DeliveryAgentReference(id: 4, createdAtMs: 77))
            let request = try JSONDecoder().decode(EngineRequest.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
            #expect(request.operation == "start" && request.kind == "codex" && request.task == "task")
            #expect(request.session == "session" && request.isolate == true)
            #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
        }
        try await fixture(#"{"protocol":1,"ok":true,"result":{"agentId":4}}"#) { (client, _) async throws in
            #expect(try await client.start(kind: "codex", cwd: "/fixture", name: "new", task: "task") == 4)
        }
        for fields in [#"{"agentId":4}"#, #"{"agentId":4,"createdAtMs":-1}"#, #"{"agentId":4,"createdAtMs":0}"#] {
            try await fixture("{\"protocol\":1,\"ok\":true,\"result\":" + fields + "}") { (client, root) async throws in
                await #expect(throws: EngineClientError.invalidResponse) {
                    try await client.startIdentified(kind: "codex", cwd: "/fixture", name: "new", task: "task")
                }
                #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
            }
        }
    }
}
