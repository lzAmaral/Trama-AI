import Foundation

/// One snapshot at a time, with coalesced wakeups after confirmed PTY input.
/// Waking the poller never repeats input or any other mutation.
@MainActor
public final class TerminalSnapshotPoller {
    private let interval: Duration
    private let minimumInterval: Duration
    private var sleeper: Task<Void, Error>?
    private var refreshRequested = false
    private var running = false
    private var waitingRuns: [CheckedContinuation<Void, Never>] = []

    public init(interval: Duration = .milliseconds(800), minimumInterval: Duration = .milliseconds(100)) {
        self.interval = max(.zero, interval)
        self.minimumInterval = max(.zero, minimumInterval)
    }

    public func requestRefresh() {
        refreshRequested = true
        sleeper?.cancel()
    }

    public func run(poll: @MainActor () async -> Void) async {
        // SwiftUI can start a replacement task before the cancelled RPC unwinds.
        // Wait for its owner rather than lose the new task or overlap snapshots.
        while running {
            await withCheckedContinuation { waitingRuns.append($0) }
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        running = true
        defer {
            running = false
            sleeper = nil
            let waiting = waitingRuns
            waitingRuns.removeAll()
            for continuation in waiting { continuation.resume() }
        }
        let clock = ContinuousClock()
        var lastPoll: ContinuousClock.Instant?
        while !Task.isCancelled {
            // A burst of typing cannot create overlapping or unbounded requests.
            if let lastPoll {
                do { try await clock.sleep(until: lastPoll.advanced(by: minimumInterval)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            refreshRequested = false
            lastPoll = clock.now
            await poll()
            guard !Task.isCancelled else { return }
            if refreshRequested { continue }
            let delay = Task { try await Task.sleep(for: interval) }
            sleeper = delay
            await withTaskCancellationHandler {
                _ = try? await delay.value
            } onCancel: {
                delay.cancel()
            }
            sleeper = nil
        }
    }
}
