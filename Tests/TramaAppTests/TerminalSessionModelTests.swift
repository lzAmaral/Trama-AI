import Combine
import Foundation
import Testing
import TramaCore
@testable import TramaApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSessionModelTests {
    @Test func unchangedSnapshotsDoNotRepublishTheTerminalAndAnErrorCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-terminal-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = root.appendingPathComponent("response.json")
        let engine = root.appendingPathComponent("engine")
        let script = "#!/bin/sh\n/bin/cat > /dev/null\n/bin/cat \"$(/usr/bin/dirname \"$0\")/response.json\"\n"
        try Data(script.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let envelope = try JSONSerialization.data(withJSONObject: ["protocol": 1, "ok": true,
            "result": ["data": Data("controlled output".utf8).base64EncodedString(), "rows": 24, "cols": 80]])
        try envelope.write(to: response)
        let model = TerminalSessionModel(client: OctoEngineClient(executableURL: engine, homeURL: root), id: 1, createdAtMs: 1, delivered: { _ in })
        var frames = 0, readiness = 0, errors = 0
        let subscriptions = [model.$snapshot.dropFirst().sink { _ in frames += 1 },
                             model.$hasSnapshot.dropFirst().sink { _ in readiness += 1 },
                             model.$error.dropFirst().sink { _ in errors += 1 }]
        await model.poll()
        await model.poll()
        #expect(frames == 1 && readiness == 1 && errors == 0)
        try Data("invalid".utf8).write(to: response)
        await model.poll()
        #expect(model.error != nil)
        try envelope.write(to: response)
        await model.poll()
        #expect(model.error == nil)
        #expect(frames == 1 && readiness == 1 && errors == 2)
        withExtendedLifetime(subscriptions) {}
    }
    @Test func slowDeliveryBookkeepingDoesNotHoldTheNextInputAndKeepsDeliveryOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-terminal-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("engine")
        let requests = root.appendingPathComponent("requests.jsonl")
        let script = #"""
        #!/bin/sh
        /bin/cat >> "$(/usr/bin/dirname "$0")/requests.jsonl"
        printf '\n' >> "$(/usr/bin/dirname "$0")/requests.jsonl"
        printf '{"protocol":1,"ok":true,"result":{}}'
        """#
        try Data(script.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let began = DeliveryGate(), release = DeliveryGate(), finished = DeliveryGate()
        var dates: [Date] = []
        let model = TerminalSessionModel(client: OctoEngineClient(executableURL: engine, homeURL: root), id: 1, createdAtMs: 1, delivered: { date in
            dates.append(date)
            if dates.count == 1 {
                began.open()
                await release.wait()
            } else { finished.open() }
        })
        model.input(Data("first".utf8))
        await began.wait()
        defer { release.open() }
        model.input(Data("second".utf8))
        let deadline = ContinuousClock.now + .seconds(2)
        var lines: [Substring] = []
        while ContinuousClock.now < deadline {
            lines = (try? String(contentsOf: requests, encoding: .utf8))?.split(separator: "\n") ?? []
            if lines.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lines.count == 2)
        #expect(dates.count == 1)
        release.open()
        await finished.wait()
        #expect(dates.count == 2)
        #expect(dates[0] <= dates[1])
        model.suspend()
    }

    @Test func closingTheDetailDuringInputPreservesItsConfirmedDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-terminal-close-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("engine")
        let entered = root.appendingPathComponent("entered")
        let release = root.appendingPathComponent("release")
        let script = #"""
        #!/bin/sh
        base=$(/usr/bin/dirname "$0")
        /bin/cat > /dev/null
        /usr/bin/touch "$base/entered"
        attempts=0
        while [ ! -f "$base/release" ] && [ "$attempts" -lt 200 ]; do
            /bin/sleep 0.01
            attempts=$((attempts+1))
        done
        printf '{"protocol":1,"ok":true,"result":{}}'
        """#
        try Data(script.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let delivered = DeliveryGate()
        var count = 0
        var model: TerminalSessionModel? = TerminalSessionModel(client: OctoEngineClient(executableURL: engine, homeURL: root), id: 1, createdAtMs: 1, delivered: { _ in count += 1; delivered.open() })
        weak var reference = model
        model?.input(Data("once".utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: entered.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: entered.path))
        model?.suspend()
        model = nil
        #expect(reference == nil)
        try Data().write(to: release)
        await delivered.wait()
        #expect(count == 1)
    }

}


@MainActor private final class DeliveryGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
