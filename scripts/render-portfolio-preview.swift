// Portfolio captures of the actual SwiftUI views with isolated, explicitly fictional fixtures.
// No real provider or holder is launched. Build with the same object list as render-workspace-preview.swift.
import AppKit
import SwiftUI
import TramaCore
@testable import TramaApp

@main struct PortfolioPreview {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trama-demo-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(fileURL: root.appendingPathComponent("projects.json"))
        var projects: [Project] = []
        for name in ["website", "app-mobile", "infra"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects = try repository.register(folder).projects
        }
        let names = ["revisar-navegacao", "integrar-cadastro", "atualizar-icones", "preparar-testes"]
        let states = ["paused", "working", "done", "idle"]
        let activities = ["Revisar a navegação do projeto", "Implementar o formulário de cadastro", "Atualização dos ícones", "Preparar testes locais"]
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let agents = names.indices.map { i in
            EngineAgent(id: UInt32(i + 1), name: names[i], kind: i % 2 == 0 ? "codex" : "claude", state: states[i], session: "portfolio", cwd: projects[0].path, project: projects[0].path, task: activities[i], activity: activities[i], createdAtMs: timestamp - UInt64((i + 1) * 60000))
        }
        try JSONEncoder().encode(EngineSessionList(agents: agents, sessions: ["portfolio"]))
            .write(to: root.appendingPathComponent("list.json"))
        let inspection: [String: Any] = ["protocol": 1, "engine": "octo", "upstreamRevision": OctoEngineClient.supportedRevision,
            "upstreamVersion": "0.2.19", "providers": [["id": "claude", "installed": true], ["id": "codex", "installed": true]],
            "agentCount": agents.count, "operations": ["inspect", "list"]]
        try JSONSerialization.data(withJSONObject: inspection).write(to: root.appendingPathComponent("inspect.json"))
        let engine = root.appendingPathComponent("fixture-engine")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        if '--inspect' in sys.argv:
            print((root / 'inspect.json').read_text())
        else:
            request = json.load(sys.stdin)
            if request.get('operation') == 'list':
                print(json.dumps({'protocol': 1, 'ok': True, 'result': json.loads((root / 'list.json').read_text())}))
            else:
                print(json.dumps({'protocol': 1, 'ok': False, 'error': 'Prévia de portfólio: operação bloqueada'}))
        """#
        try Data(script.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let model = LiveWorkspaceModel(client: OctoEngineClient(executableURL: engine, homeURL: root.appendingPathComponent("engine")), navigationRepository: WorkspaceNavigationRepository(fileURL: root.appendingPathComponent("navigation.json")))
        model.configure(projects: projects)
        await model.refresh()
        await model.loadProviders()
        guard model.connectionError == nil, model.providerError == nil else { throw NSError(domain: "Portfolio", code: 1) }
        model.selectScope(projectID: projects[0].id, session: "portfolio")
        let workspace = WorkspaceModel(repository: repository)
        workspace.selectedID = projects[0].id
        let view = WorkspaceView(workspace: workspace, live: model)
            .environment(\.scenePhase, .active)
            .preferredColorScheme(.dark).tint(TerminalTheme.accent)
            .overlay(alignment: .topTrailing) {
                Text("PRÉVIA • DADOS FICTÍCIOS").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TerminalTheme.accent).padding(12).background(.black)
            }
        try await capture(view, to: output.appendingPathComponent("trama-workspace.png"))
        model.showOverview(.list)
        try await capture(view, to: output.appendingPathComponent("trama-list.png"))
        model.showOverview(.board)
        model.projectTaskDrafts[projects[0].id] = "Revisar a navegação e os estados vazios do website."
        try await capture(view, to: output.appendingPathComponent("trama-composer.png"))
        print("Três capturas nativas; dados fictícios; nenhum provedor iniciado.")
    }

    @MainActor static func capture<V: View>(_ view: V, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw NSError(domain: "Portfolio", code: 2) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Portfolio", code: 3) }
        try png.write(to: url)
    }
}
