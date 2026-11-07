import Foundation
import Testing
@testable import TramaCore

@MainActor
struct TerminalActionQueueTests {
    @Test func resizeAndInputNeverRunConcurrently() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue()
        queue.resize(rows: 30, cols: 90)
        await transport.resizeStarted.wait()
        #expect(queue.input(Data("hello".utf8)))
        #expect(transport.events == ["resize:30:90"])
        transport.releaseResize.open()
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:30:90", "input:hello"])
        #expect(transport.maxActive == 1)
    }

    @Test func suspendDropsUnsentInputAndReconnectReappliesSize() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue()
        queue.resize(rows: 40, cols: 120)
        await transport.resizeStarted.wait()
        #expect(queue.input(Data("discarded".utf8)))
        queue.suspend()
        #expect(!queue.input(Data("inactive".utf8)))
        queue.resume()
        #expect(queue.input(Data("fresh".utf8)))
        transport.releaseResize.open()
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:40:120", "resize:40:120", "input:fresh"])
        #expect(transport.maxActive == 1)
    }

    @Test func returningToInFlightSizeDiscardsSupersededPendingResize() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue()
        queue.resize(rows: 30, cols: 90)
        await transport.resizeStarted.wait()
        queue.resize(rows: 40, cols: 120)
        queue.resize(rows: 30, cols: 90)
        #expect(queue.input(Data("after-resize".utf8)))
        transport.releaseResize.open()
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:30:90", "input:after-resize"])
        #expect(transport.maxActive == 1)
    }

    @Test func returningToAppliedSizeDiscardsResizeThatHasNotStarted() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue()
        transport.releaseResize.open()
        queue.resize(rows: 30, cols: 90)
        await queue.waitUntilIdle()
        queue.resize(rows: 40, cols: 120)
        queue.resize(rows: 30, cols: 90)
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:30:90"])
        #expect(transport.maxActive == 1)
    }

    @Test func matchingInFlightSizeFromOldGenerationStillReappliesAfterResume() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue()
        queue.resize(rows: 30, cols: 90)
        await transport.resizeStarted.wait()
        queue.suspend()
        queue.resize(rows: 40, cols: 120)
        queue.resume()
        queue.resize(rows: 30, cols: 90)
        transport.releaseResize.open()
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:30:90", "resize:30:90"])
        #expect(transport.maxActive == 1)
    }

    @Test func failedInputIsNotRetriedAndQueuedInputIsDiscarded() async {
        let started = TerminalGate()
        let release = TerminalGate()
        var inputs: [Data] = []
        var failures: [TerminalActionQueue.Failure] = []
        let queue = TerminalActionQueue(sendInput: { data in
            inputs.append(data)
            started.open()
            await release.wait()
            throw ControlledTerminalError.uncertain
        }, sendResize: { _, _ in }, onFailure: { failures.append($0) })
        #expect(queue.input(Data("sent-once".utf8)))
        await started.wait()
        #expect(queue.input(Data("not-sent".utf8)))
        release.open()
        await queue.waitUntilIdle()
        #expect(inputs == [Data("sent-once".utf8)])
        #expect(failures.count == 1)
        if case .input = failures.first { } else { Issue.record("Expected an input failure") }
    }

    @Test func failureFromSuspendedGenerationDoesNotDropFreshInput() async {
        let started = TerminalGate()
        let release = TerminalGate()
        var inputs: [Data] = []
        var failures: [TerminalActionQueue.Failure] = []
        let queue = TerminalActionQueue(sendInput: { data in
            inputs.append(data)
            if inputs.count == 1 {
                started.open()
                await release.wait()
                throw ControlledTerminalError.uncertain
            }
        }, sendResize: { _, _ in }, onFailure: { failures.append($0) })
        #expect(queue.input(Data("old-holder".utf8)))
        await started.wait()
        queue.suspend()
        queue.resume()
        #expect(queue.input(Data("new-holder".utf8)))
        release.open()
        await queue.waitUntilIdle()
        #expect(inputs == [Data("old-holder".utf8), Data("new-holder".utf8)])
        #expect(failures.isEmpty)
    }

    @Test func byteLimitRejectsWholePasteAndPreservesAcceptedBytes() async {
        let transport = ControlledTerminalTransport()
        let queue = transport.queue(maxPendingBytes: 4)
        queue.resize(rows: 24, cols: 80)
        await transport.resizeStarted.wait()
        #expect(queue.input(Data("1234".utf8)))
        #expect(!queue.input(Data("5".utf8)))
        transport.releaseResize.open()
        await queue.waitUntilIdle()
        #expect(transport.events == ["resize:24:80", "input:1234"])
    }

    @Test func failedResizeConvergesOnSnapshotWithoutRetryingInput() async {
        var sizes: [String] = []
        var attempts = 0
        let queue = TerminalActionQueue(sendInput: { _ in Issue.record("Unexpected input") }, sendResize: { rows, cols in
            sizes.append("\(rows):\(cols)")
            attempts += 1
            if attempts == 1 { throw ControlledTerminalError.uncertain }
        })
        queue.resize(rows: 500, cols: 900)
        await queue.waitUntilIdle()
        queue.reconcile(rows: 24, cols: 80)
        await queue.waitUntilIdle()
        queue.reconcile(rows: 100, cols: 240)
        await queue.waitUntilIdle()
        #expect(sizes == ["100:240", "100:240"])
    }
}

private enum ControlledTerminalError: Error { case uncertain }

@MainActor
private final class TerminalGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class ControlledTerminalTransport {
    let resizeStarted = TerminalGate()
    let releaseResize = TerminalGate()
    var events: [String] = []
    var active = 0
    var maxActive = 0

    func queue(maxPendingBytes: Int = 24_000) -> TerminalActionQueue {
        TerminalActionQueue(maxPendingBytes: maxPendingBytes, sendInput: { [self] data in
            begin("input:" + String(decoding: data, as: UTF8.self))
            active -= 1
        }, sendResize: { [self] rows, cols in
            begin("resize:\(rows):\(cols)")
            resizeStarted.open()
            await releaseResize.wait()
            active -= 1
        })
    }

    private func begin(_ event: String) {
        events.append(event)
        active += 1
        maxActive = max(maxActive, active)
    }
}
