import Combine
import Foundation
import Testing
@testable import TramaCore
@testable import TramaApp

@MainActor
@Suite(.serialized)
struct DeliveryWorkflowViewModelTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        func get() -> Bool { lock.withLock { value } }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("trama-workflow-ui-" + UUID().uuidString)
    }

    private func agent(_ root: URL, state: String) -> EngineAgent {
        EngineAgent(id: 1, name: "Controlled", kind: "terminal", state: state,
                    session: "default", cwd: root.path, project: root.path, task: "Fixture", activity: "", createdAtMs: 1)
    }

    @Test func initializationDoesNotTouchDiskAndFirstObservationLoadsExistingState() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = DeliveryWorkflowViewModel(engineHome: root)
        #expect(model.snapshot == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await model.observe([agent(root, state: "paused")])
        #expect(model.error == nil)
        let item = try #require(model.pending.first)
        #expect(item.kind == .paused)
        await model.opened(item.agentRef, panel: "terminal")
        #expect(model.pending.first?.readAt != nil)
        await model.inputDelivered(item.agentRef, sentAt: item.createdAt)
        #expect(model.pending.first?.inputDeliveredAt != nil)
        #expect(model.pending.first?.isPending == true)
    }

    @Test func storageOperationsAllowMainActorProgressAndPublishInQueueOrder() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = DeliveryWorkflowViewModel(engineHome: root)
        let began = Flag(), ranOnMain = Flag(), mainProgress = Flag()
        let gate = DispatchSemaphore(value: 0)
        let first = Task { @MainActor in
            await model.update { repository in
                if Thread.isMainThread { ranOnMain.set() }
                began.set()
                // A bounded wait guarantees that a regression cannot hang the whole test suite.
                _ = gate.wait(timeout: .now() + 2)
                return try repository.setMetricsEnabled(true)
            }
        }
        defer { gate.signal() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !began.get(), clock.now < deadline { await Task.yield() }
        #expect(began.get())
        mainProgress.set()
        let second = Task { @MainActor in await model.update { try $0.recordVisit() } }
        // Both enqueue operations have reached MainActor before the first I/O operation is released.
        await Task.yield()
        gate.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(!ranOnMain.get())
        #expect(mainProgress.get())
        #expect(model.snapshot?.metrics.enabled == true)
        #expect(model.snapshot?.metrics.summary.visits == 1)
        #expect(try model.repository.load() == model.snapshot)
    }

    @Test func corruptInitialDataIsPreservedAndAnExplicitReloadRecovers() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("trama-delivery-workflow.json")
        let corrupt = Data("preserve invalid workflow".utf8)
        try corrupt.write(to: file)
        let model = DeliveryWorkflowViewModel(engineHome: root)
        await model.observe([agent(root, state: "paused")])
        #expect(model.snapshot == nil)
        #expect(model.error != nil)
        #expect(await model.update({ try $0.recordVisit() }) == false)
        #expect(try Data(contentsOf: file) == corrupt)
        try JSONEncoder().encode(DeliveryWorkflowSnapshot()).write(to: file)
        await model.reload()
        #expect(model.error == nil)
        await model.observe([agent(root, state: "paused")])
        #expect(model.pending.count == 1)
    }

    @Test func identicalObservationsDoNotRepublishTheWorkflow() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = DeliveryWorkflowViewModel(engineHome: root)
        let agents = [agent(root, state: "idle")]
        await model.observe(agents)
        let published = Flag()
        let subscription = model.objectWillChange.sink { published.set() }
        await model.observe(agents)
        #expect(!published.get())
        withExtendedLifetime(subscription) {}
    }

    @Test func successfulCommentInsertionRemainsAcknowledgedWhenRefreshFails() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workflow.json")
        let savedFile = root.appendingPathComponent("saved.json")
        let repository = DeliveryWorkflowRepository(fileURL: file, now: Date.init, writer: { data, destination in
            try data.write(to: destination, options: .atomic)
            // Simulate an external filesystem change between acknowledged insert and refresh.
            try FileManager.default.copyItem(at: destination, to: savedFile)
            try Data("changed externally after confirmed insert".utf8).write(to: destination, options: .atomic)
        })
        let model = DeliveryWorkflowViewModel(repository: repository)
        #expect(await model.addComment(ref: .init(id: 1, createdAtMs: 1), version: String(repeating: "a", count: 64), line: 1, text: "Saved once"))
        #expect(model.error?.contains("Nota salva") == true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let saved = try decoder.decode(DeliveryWorkflowSnapshot.self, from: Data(contentsOf: savedFile))
        #expect(saved.comments.count == 1)
        #expect(saved.comments.first?.text == "Saved once")
    }
}
