// Native UI memory study. Run only through benchmark-ui-memory.py with an isolated engine home.
import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import TramaCore
@testable import TramaApp

@MainActor final class MemoryScene: ObservableObject {
    @Published var active = true
}

@MainActor final class WeakTerminalReference {
    weak var value: TerminalView?
    init(_ value: TerminalView) { self.value = value }
}

struct StudyRoot: View {
    @ObservedObject var scene: MemoryScene
    let workspace: WorkspaceModel
    let live: LiveWorkspaceModel
    var body: some View {
        WorkspaceView(workspace: workspace, live: live)
            .environment(\.scenePhase, scene.active ? .active : .inactive)
            .preferredColorScheme(.dark)
            .overlay(alignment: .bottomTrailing) {
                Text("Teste de memória · shells isolados").font(.system(size: 10))
                    .padding(6).background(.black).foregroundStyle(.yellow)
            }
    }
}

@main struct UIMemoryStudy {
    @MainActor static var samples: [[String: Any]] = []
    @MainActor static var started = ProcessInfo.processInfo.systemUptime

    @MainActor static func terminals(_ root: NSView) -> [TerminalView] {
        (root as? TerminalView).map { [$0] } ?? root.subviews.flatMap(terminals)
    }

    @MainActor static func record(_ phase: String, root: NSView) throws {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw failure("task_info failed") }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        samples.append(["phase": phase, "seconds": ProcessInfo.processInfo.systemUptime - started,
                        "footprintBytes": info.phys_footprint, "residentBytes": info.resident_size,
                        "cpuSeconds": cpu, "terminalViews": terminals(root).count])
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "UIMemoryStudy", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    @MainActor static func sample(_ phase: String, seconds: Double, root: NSView) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            try record(phase, root: root)
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5 else { throw failure("Expected engine, root, mode, output") }
        let engine = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3]
        let output = URL(fileURLWithPath: CommandLine.arguments[4])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let repository = ProjectRepository(fileURL: root.appendingPathComponent("projects.json"))
        let projects = try repository.register(root.appendingPathComponent("controlled project")).projects
        let client = OctoEngineClient(executableURL: engine, homeURL: root.appendingPathComponent("engine home"), timeout: 15)
        let live = LiveWorkspaceModel(client: client,
            navigationRepository: WorkspaceNavigationRepository(fileURL: root.appendingPathComponent("navigation.json")))
        live.configure(projects: projects)
        await live.refresh()
        guard live.agents.count == 6, live.connectionError == nil else { throw failure("Expected six isolated shells") }
        let agents = live.agents
        let workspace = WorkspaceModel(repository: repository)
        let scene = MemoryScene()
        live.terminalPreviewDensity = mode == "grid2" ? .economical : .full
        if mode == "terminal" { live.open(agents[0]) }
        else { live.showOverview(mode == "grid" || mode == "grid2" ? .grid : .list) }
        let hosting = NSHostingView(rootView: StudyRoot(scene: scene, workspace: workspace, live: live))
        hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trama — teste de memória isolado"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        try await sample("warmup", seconds: 4, root: hosting)
        let expected = mode == "grid" ? 6 : mode == "grid2" ? 2 : mode == "terminal" ? 1 : 0
        guard terminals(hosting).count == expected else { throw failure("Wrong terminal count for \(mode)") }
        try await sample("idle", seconds: 4, root: hosting)
        // Only this fixed local shell script is delivered; no provider task is started.
        let script = root.appendingPathComponent("controlled project/generate-output.sh").path
        let command = "/bin/sh '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
        for agent in agents { try await client.sendInput(agentId: agent.id, data: Data(command.utf8), createdAtMs: agent.createdAtMs) }
        try await sample("output", seconds: 9, root: hosting)
        for agent in agents {
            let snapshot = try await client.snapshot(agentId: agent.id)
            guard snapshot.bytes.map({ String(decoding: $0, as: UTF8.self).contains("TRAMA_MEMORY_COMPLETE") }) == true else {
                throw failure("Shell output completion missing")
            }
        }
        try await sample("settled", seconds: 3, root: hosting)
        let renderedMarkers = terminals(hosting).filter { view in
            let terminal = view.getTerminal()
            return (0..<terminal.rows).contains { row in
                terminal.getLine(row: row)?.translateToString().contains("TRAMA_MEMORY_COMPLETE") == true
            }
        }.count
        guard renderedMarkers == expected else { throw failure("Completion marker absent from native terminal buffer") }
        scene.active = false
        try await sample("inactive", seconds: 4, root: hosting)
        scene.active = true
        var densityReduction: [String: Any] = ["performed": false]
        if mode == "grid" {
            // Keep this transition after all comparable steady-state phases. Weak boxes
            // must not turn the retention check itself into an owner of removed views.
            let previousViews = terminals(hosting).map(WeakTerminalReference.init)
            live.terminalPreviewDensity = .economical
            try await sample("densityReduced", seconds: 2, root: hosting)
            let currentIDs = Set(terminals(hosting).map(ObjectIdentifier.init))
            let retainedRemoved = previousViews.filter { reference in
                reference.value.map { !currentIDs.contains(ObjectIdentifier($0)) } ?? false
            }.count
            let markers = terminals(hosting).filter { view in
                let terminal = view.getTerminal()
                return (0..<terminal.rows).contains { row in
                    terminal.getLine(row: row)?.translateToString().contains("TRAMA_MEMORY_COMPLETE") == true
                }
            }.count
            guard currentIDs.count == 2, retainedRemoved == 0, markers == 2 else {
                throw failure("Density reduction retained removed terminals or lost visible output")
            }
            densityReduction = ["performed": true, "initialTerminalViews": previousViews.count,
                "finalTerminalViews": currentIDs.count, "removedViewsStillRetained": retainedRemoved,
                "previousViewsReleasedWithinTwoSeconds": previousViews.filter { $0.value == nil }.count,
                "nativeTerminalBuffersWithCompletionMarker": markers]
        }
        var released = 0
        if mode == "cycles" {
            for cycle in 0..<20 {
                live.open(agents[cycle % agents.count])
                try await sample("open-\(cycle)", seconds: 1, root: hosting)
                guard terminals(hosting).count == 1 else { throw failure("Cycle terminal absent") }
                weak var terminal = terminals(hosting).first
                live.close(agents[cycle % agents.count].deliveryReference!)
                live.showOverview(.list)
                try await sample("closed-\(cycle)", seconds: 1, root: hosting)
                guard terminals(hosting).isEmpty else { throw failure("Cycle terminal still attached") }
                if terminal == nil { released += 1 }
            }
            try await sample("afterCycles", seconds: 4, root: hosting)
        }
        guard live.connectionError == nil else { throw failure("Engine error during UI study") }
        let report: [String: Any] = ["schema": 1, "mode": mode, "samples": samples,
            "visibleWindow": window.isVisible, "expectedTerminalViews": expected,
            "outputCompletionConfirmed": true, "cycles": mode == "cycles" ? 20 : 0,
            "nativeTerminalBuffersWithCompletionMarker": renderedMarkers,
            "densityReduction": densityReduction,
            "terminalViewsReleasedWithinOneSecond": released,
            "limitations": ["Scene phase is injected to make scenarios deterministic; focus and keyboard latency are not measured.",
                            "Visible NSWindow and terminal buffer markers are checked; rendered pixels are not inspected by this benchmark.",
                            "Measures the UI process only; holder/CLI memory is measured separately.",
                            "AppKit/SwiftUI caches may remain after view release; growth alone does not establish a leak."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("UI memory study completed: \(mode)")
    }
}
