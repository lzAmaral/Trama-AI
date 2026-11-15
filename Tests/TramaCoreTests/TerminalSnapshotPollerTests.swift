import Foundation
import Testing
@testable import TramaCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalSnapshotPollerTests {
    @Test func confirmedInputWakesAnIdlePollerWithoutWaitingForItsInterval() async {
        let poller = TerminalSnapshotPoller(interval: .seconds(30), minimumInterval: .milliseconds(10))
        let first = SnapshotGate(), refreshed = SnapshotGate()
        var count = 0
        let worker = Task {
            await poller.run {
                count += 1
                if count == 1 { first.open() } else { refreshed.open() }
            }
        }
        await first.wait()
        // Let the first poll install its idle wait before asking for fresh output.
        await Task.yield()
        let clock = ContinuousClock(), start = ContinuousClock.now
        poller.requestRefresh()
        await refreshed.wait()
        worker.cancel()
        await worker.value
        // Other AppKit suites can occupy MainActor during startup; distinguish a wake from the 30 s idle interval.
        #expect(start.duration(to: clock.now) < .seconds(5))
        #expect(count == 2)
    }

    @Test func requestsDuringAnInflightSnapshotCoalesceWithoutOverlappingPolls() async {
        let poller = TerminalSnapshotPoller(interval: .seconds(30), minimumInterval: .milliseconds(10))
        let entered = SnapshotGate(), release = SnapshotGate(), refreshed = SnapshotGate()
        var count = 0, active = 0, maximumActive = 0
        let worker = Task {
            await poller.run {
                count += 1; active += 1; maximumActive = max(maximumActive, active)
                if count == 1 {
                    entered.open()
                    await release.wait()
                } else { refreshed.open() }
                active -= 1
            }
        }
        await entered.wait()
        for _ in 0..<100 { poller.requestRefresh() }
        release.open()
        await refreshed.wait()
        worker.cancel()
        await worker.value
        #expect(count == 2)
        #expect(maximumActive == 1)
    }

    @Test func cancellingAnIdlePollerEndsPromptlyAndAllowsRestart() async {
        let poller = TerminalSnapshotPoller(interval: .seconds(30))
        let first = SnapshotGate(), restarted = SnapshotGate()
        let worker = Task { await poller.run { first.open() } }
        await first.wait()
        await Task.yield()
        let start = ContinuousClock.now
        worker.cancel()
        await worker.value
        #expect(start.duration(to: .now) < .seconds(5))
        let next = Task { await poller.run { restarted.open() } }
        await restarted.wait()
        next.cancel()
        await next.value
    }

    @Test func replacementWaitsForCancelledSnapshotAndDoesNotLoseItsPollingTask() async {
        let poller = TerminalSnapshotPoller(interval: .seconds(30))
        let entered = SnapshotGate(), release = SnapshotGate(), restarted = SnapshotGate()
        var active = 0, maximumActive = 0
        let old = Task {
            await poller.run {
                active += 1; maximumActive = max(maximumActive, active)
                entered.open()
                await release.wait()
                active -= 1
            }
        }
        await entered.wait()
        old.cancel()
        let next = Task {
            await poller.run {
                active += 1; maximumActive = max(maximumActive, active)
                restarted.open()
                active -= 1
            }
        }
        await Task.yield()
        release.open()
        await restarted.wait()
        next.cancel()
        await old.value; await next.value
        #expect(maximumActive == 1)
    }
}

@MainActor private final class SnapshotGate {
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
