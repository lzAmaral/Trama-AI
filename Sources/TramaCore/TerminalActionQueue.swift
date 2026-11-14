import Foundation

/// Serializes mutations for one PTY. Suspending drops unsent work without retrying
/// an in-flight operation, whose outcome may be unknown after a transport failure.
@MainActor
public final class TerminalActionQueue {
    private struct Size: Sendable, Equatable {
        let rows: Int
        let cols: Int
    }

    public enum Failure: Sendable, Equatable {
        case input(String)
        case resize(String)
    }

    private let sendInput: @MainActor (Data) async throws -> Void
    private let sendResize: @MainActor (Int, Int) async throws -> Void
    private let onFailure: @MainActor (Failure) -> Void
    private let maxPendingBytes: Int
    private var pendingInput = Data()
    private var pendingResize: Size?
    private var inFlightResize: Size?
    private var inFlightResizeGeneration: Int?
    private var requestedSize: Size?
    private var appliedSize: Size?
    private var accepting = true
    private var generation = 0
    private var worker: Task<Void, Never>?

    public init(maxPendingBytes: Int = 24_000,
                sendInput: @escaping @MainActor (Data) async throws -> Void,
                sendResize: @escaping @MainActor (Int, Int) async throws -> Void,
                onFailure: @escaping @MainActor (Failure) -> Void = { _ in }) {
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.sendInput = sendInput
        self.sendResize = sendResize
        self.onFailure = onFailure
    }

    /// False means the whole input was rejected; no partial paste is submitted.
    @discardableResult
    public func input(_ data: Data) -> Bool {
        guard accepting, data.count <= maxPendingBytes - pendingInput.count else { return false }
        pendingInput.append(data)
        drain()
        return true
    }

    public func resize(rows: Int, cols: Int) {
        let size = Size(rows: max(2, min(rows, 100)), cols: max(10, min(cols, 240)))
        requestedSize = size
        guard accepting else { return }
        // Returning to this generation's in-flight or applied size supersedes
        // any intermediate pending size. An older generation still needs reapply.
        if inFlightResize == size, inFlightResizeGeneration == generation {
            pendingResize = nil
            return
        }
        if appliedSize == size, inFlightResize == nil {
            pendingResize = nil
            return
        }
        if pendingResize == size { return }
        pendingResize = size
        drain()
    }

    /// A holder restart or failed resize must converge even without a layout event.
    public func reconcile(rows: Int, cols: Int) {
        guard accepting, let size = requestedSize, size.rows != rows || size.cols != cols else { return }
        appliedSize = nil
        resize(rows: size.rows, cols: size.cols)
    }

    public func suspend() {
        accepting = false
        generation += 1
        pendingInput.removeAll()
        pendingResize = nil
        appliedSize = nil
    }

    public func resume() {
        accepting = true
        appliedSize = nil
        // Reapply after any older in-flight operation completes; it belongs to a
        // previous holder generation and cannot establish this holder's dimensions.
        pendingResize = requestedSize
        drain()
    }

    /// Waits for currently queued operations; useful when the owner needs to settle work.
    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func drain() {
        guard worker == nil, accepting, pendingResize != nil || !pendingInput.isEmpty else { return }
        worker = Task {
            defer { worker = nil }
            while accepting, pendingResize != nil || !pendingInput.isEmpty {
                let actionGeneration = generation
                if let size = pendingResize {
                    pendingResize = nil
                    inFlightResize = size
                    inFlightResizeGeneration = actionGeneration
                    do {
                        try await sendResize(size.rows, size.cols)
                        if generation == actionGeneration { appliedSize = size }
                    } catch {
                        if generation == actionGeneration {
                            appliedSize = nil
                            onFailure(.resize(error.localizedDescription))
                        }
                    }
                    inFlightResize = nil
                    inFlightResizeGeneration = nil
                } else {
                    let bytes = pendingInput
                    pendingInput.removeAll()
                    do { try await sendInput(bytes) }
                    catch {
                        if generation == actionGeneration {
                            pendingInput.removeAll()
                            onFailure(.input(error.localizedDescription))
                        }
                    }
                }
            }
        }
    }
}
