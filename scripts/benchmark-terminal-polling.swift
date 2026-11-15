// Measure scheduler wait only, without UI, RPC, providers, network or user data.
// Compile alongside Sources/TramaCore/TerminalSnapshotPoller.swift (see PERFORMANCE_VALIDATION.md).
import Foundation

@main struct TerminalPollingBenchmark {
    private enum BenchmarkError: Error { case missedIdleWindow }
    @MainActor private final class Gate {
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() { opened = true; waiting?.resume(); waiting = nil }
    }

    @MainActor static func measure(wake: Bool) async throws -> Double {
        let poller = TerminalSnapshotPoller()
        let first = Gate(), second = Gate()
        var polls = 0
        let worker = Task {
            await poller.run {
                polls += 1
                if polls == 1 { first.open() } else { second.open() }
            }
        }
        await first.wait()
        // Model an acknowledgment 25 ms after the previous snapshot, during idle wait.
        try await Task.sleep(for: .milliseconds(25))
        guard polls == 1 else {
            worker.cancel()
            await worker.value
            throw BenchmarkError.missedIdleWindow
        }
        let begin = ProcessInfo.processInfo.systemUptime
        if wake { poller.requestRefresh() }
        await second.wait()
        let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        worker.cancel()
        await worker.value
        return elapsed
    }

    static func summary(_ values: [Double]) -> [String: Any] {
        let ordered = values.sorted()
        return ["count": values.count, "medianMs": ordered[ordered.count / 2], "maxMs": ordered.last!, "samplesMs": values]
    }

    @MainActor static func main() async throws {
        var idle: [Double] = [], awake: [Double] = []
        for _ in 0..<5 { idle.append(try await measure(wake: false)) }
        for _ in 0..<10 { awake.append(try await measure(wake: true)) }
        let report: [String: Any] = [
            "schema": 1,
            "idleIntervalMs": 800, "minimumIntervalMs": 100, "acknowledgmentAfterPreviousPollMs": 25,
            "withoutWake": summary(idle), "withWake": summary(awake),
            "limits": ["Scheduler-only synthetic acknowledgment; not keyboard-to-pixel latency.",
                       "Excludes RPC, PTY, provider execution, SwiftUI and terminal parsing/drawing.",
                       "Small local sample; wall time depends on host scheduling."]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: data, as: UTF8.self))
    }
}
