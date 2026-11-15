import AppKit
import SwiftUI
import SwiftTerm
import Testing
import TramaCore
@testable import TramaApp

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalPreviewDensityTests {
    private final class State: ObservableObject {
        @Published var density = TerminalPreviewDensity.economical
        @Published var agents: [EngineAgent] = (1...8).map { id in
            EngineAgent(id: UInt32(id), name: "shell-\(id)", kind: "terminal", state: "idle",
                        session: "fixture", cwd: "/fixture", project: "/fixture", task: "", activity: "",
                        createdAtMs: UInt64(id))
        }
        var opened: UInt32?
    }

    private struct FixtureView: View {
        @ObservedObject var state: State
        let client: OctoEngineClient
        var body: some View {
            WorkspaceTerminalGrid(agents: state.agents, client: client, density: $state.density,
                                  onOpen: { state.opened = $0.id })
                .environment(\.scenePhase, .active)
        }
    }

    private func terminals(_ root: NSView) -> [TerminalView] {
        (root as? TerminalView).map { [$0] } ?? root.subviews.flatMap(terminals)
    }

    @Test func changingDensityReleasesRemovedPreviewsWithoutControllingSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trama-preview-density-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("engine")
        let requests = root.appendingPathComponent("requests.jsonl")
        let script = #"""
        #!/bin/sh
        request=$(/bin/cat)
        printf '%s\n' "$request" >> "$(/usr/bin/dirname "$0")/requests.jsonl"
        printf '{"protocol":1,"ok":true,"result":{"data":"Zml4dHVyZQ==","rows":24,"cols":80}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let state = State()
        let hosting = NSHostingView(rootView: FixtureView(state: state,
            client: OctoEngineClient(executableURL: executable, homeURL: root)))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }

        func expectPreviews(_ ids: [Int]) async throws {
            let expected = Set(ids.map { "Terminal de shell-\($0)" })
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                hosting.layoutSubtreeIfNeeded()
                if Set(terminals(hosting).compactMap { $0.accessibilityLabel() }) == expected { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(Set(terminals(hosting).compactMap { $0.accessibilityLabel() }) == expected)
        }

        try await expectPreviews([1, 2])
        state.density = .full
        try await expectPreviews([1, 2, 3, 4, 5, 6])
        weak var removed = terminals(hosting).first { $0.accessibilityLabel() == "Terminal de shell-3" }
        #expect(removed != nil)
        state.density = .economical
        try await expectPreviews([1, 2])
        let releaseDeadline = ContinuousClock.now + .seconds(2)
        while removed != nil, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(removed == nil)
        // Changing scope must drop the old previews without opening or stopping a session.
        weak var previousScope = terminals(hosting).first
        state.agents = Array(state.agents.suffix(2))
        try await expectPreviews([7, 8])
        let scopeDeadline = ContinuousClock.now + .seconds(2)
        while previousScope != nil, ContinuousClock.now < scopeDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(previousScope == nil)
        #expect(state.opened == nil)
        let operations = try String(contentsOf: requests, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0["operation"] as? String == "snapshot" })
    }
}
