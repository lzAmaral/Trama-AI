// Offscreen native UI validation with isolated fixtures; never uses the user's engine or project store.
// Layout and example naming reference: lucasmarujo/octo 1dc08a44 (MIT); see ThirdPartyNotices/Octo-MIT.txt.
// Run through render-workspace-preview.sh after a local Swift build.
import AppKit
import SwiftUI
import TramaCore
@testable import TramaApp

@main struct WorkspacePreview {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let responsive = CommandLine.arguments.contains("--responsive")
        let sessionPreview = CommandLine.arguments.contains("--project-sessions")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sessionName = responsive ? "Criação de Mídia — pesquisa de mercado e lançamento do produto" : "default"
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = ProjectRepository(fileURL: root.appendingPathComponent("projects.json"))
        var projects: [Project] = []
        for name in responsive ? ["plataforma-veterinaria-controle-reprodutivo-e-gestao-de-clientes", "aplicativo-multiplataforma-de-acompanhamento-clinico", "infraestrutura-e-automacao-de-entregas"] : ["studio", "web", "infra"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects = try repository.register(folder).projects
        }
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let names = responsive ? ["investigar-concorrencia-no-cadastro-a1b2c3", "refatorar-integracao-do-motor-em-swift-d4e5", "preparar-ambiente-de-desenvolvimento-f6g7", "atualizar-icones-e-acessibilidade-h8i9j0", "revisar-fluxo-de-cadastro-de-clientes-k1l2", "compilar-aplicativos-e-validar-testes-m3n4", "verificar-saida-do-servidor-de-api-p5q6", "terminal-local-de-desenvolvimento-r7s8"] : ["sidebar-sessions", "physics-merge", "docker-install", "folder-icon-update", "checkout-redesign", "simulator-builds", "npm-start-error", "terminal-local"]
        let states = ["paused", "working", "working", "done", "done", "done", "idle", "idle"]
        let activities = ["Aguardando revisão da navegação", "Integrando alterações no motor", "Preparando o ambiente de desenvolvimento", "Atualização dos ícones de pasta", "Revisão do fluxo de cadastro", "Compilando os aplicativos locais", "Verificando a saída do servidor", "Shell controlado de demonstração"]
        let agents = names.indices.map { index in
            let project = projects[responsive || sessionPreview ? 0 : index % projects.count]
            return EngineAgent(id: UInt32(index + 1), name: names[index], kind: index == 7 ? "terminal" : index % 3 == 0 ? "codex" : "claude",
                state: states[index], session: sessionName, cwd: project.path, project: project.path,
                task: activities[index], activity: activities[index], branch: index == 1 ? (responsive ? "trama/refatoracao-da-integracao-nativa-e-correcao-dos-caminhos-de-erro" : "trama/physics-merge") : nil,
                createdAtMs: timestamp - UInt64((index + 1) * 45000))
        }
        try JSONEncoder().encode(EngineSessionList(agents: agents, sessions: [sessionName, "api-migration", "weekend"]))
            .write(to: root.appendingPathComponent("list.json"))
        let inspection: [String: Any] = ["protocol": 1, "engine": "octo", "upstreamRevision": OctoEngineClient.supportedRevision,
            "upstreamVersion": "0.2.19", "providers": [["id": "claude", "installed": true], ["id": "codex", "installed": true], ["id": "terminal", "installed": true]],
            "agentCount": agents.count, "operations": ["inspect", "list", "snapshot", "skills"]]
        try JSONSerialization.data(withJSONObject: inspection).write(to: root.appendingPathComponent("inspect.json"))
        let engine = root.appendingPathComponent("fake-engine")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, base64
        root = pathlib.Path(__file__).parent
        if '--inspect' in sys.argv:
            print((root / 'inspect.json').read_text())
        else:
            request = json.load(sys.stdin)
            op = request.get('operation')
            with (root / 'operations.txt').open('a') as log: log.write(str(op) + '\n')
            if op == 'list': result = json.loads((root / 'list.json').read_text())
            elif op == 'snapshot':
                text = '\x1b[H\x1b[2J\x1b[32mPrévia com dados fictícios\x1b[0m\r\n\r\n> Verificando alterações locais\r\n\r\n  ✓ Compilação preparada\r\n  ✓ Testes controlados\r\n\r\nNenhum provedor real foi iniciado.\r\n'
                result = {'data': base64.b64encode(text.encode()).decode(), 'rows': 24, 'cols': 100}
            elif op == 'skills': result = {'skills': [{'name': 'revisar-interface-e-acessibilidade-' + str(i), 'description': 'Skill fictícia para testar descrições longas no seletor nativo', 'invocation': '/revisar-interface-' + str(i)} for i in range(12)]}
            elif op == 'resize': result = {}
            else:
                print(json.dumps({'protocol': 1, 'ok': False, 'error': 'Operação bloqueada no fixture de prévia'})); sys.exit(0)
            print(json.dumps({'protocol': 1, 'ok': True, 'result': result}))
        """#
        try Data(script.utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let client = OctoEngineClient(executableURL: engine, homeURL: root.appendingPathComponent("engine"))
        let navigation = WorkspaceNavigationRepository(fileURL: root.appendingPathComponent("navigation.json"))
        let model = LiveWorkspaceModel(client: client, navigationRepository: navigation)
        model.configure(projects: projects)
        await model.refresh()
        await model.loadProviders()
        guard model.connectionError == nil, model.providerError == nil else {
            throw NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: model.connectionError ?? model.providerError ?? "Fixture error"])
        }
        model.selectSession(sessionName)
        let workspace = WorkspaceModel(repository: repository)
        if sessionPreview {
            try model.renameProjectSession(sessionName, name: "Geral", projectID: projects[0].id)
            try model.createProjectSession(name: "Landing page", projectID: projects[0].id)
            model.selectScope(projectID: projects[0].id, session: sessionName)
            workspace.selectedID = projects[0].id
        }
        if responsive {
            model.selectProject(projects[0].id)
            workspace.selectedID = projects[0].id
            model.projectTaskDrafts[projects[0].id] = "Prévia com dados fictícios: revisar o cadastro e a navegação.\nPreservar caracteres: ação, 👩🏽‍💻, \"aspas\" e caminhos longos.\nNenhum agente real será iniciado por este teste."
        }
        let view = WorkspaceView(workspace: workspace, live: model)
            .environment(\.scenePhase, .active) // Offscreen fixtures have no active native scene.
            .preferredColorScheme(.dark).tint(TerminalTheme.accent)
            .overlay(alignment: .bottomTrailing) {
                Text("Prévia · dados fictícios").font(.system(size: 10)).foregroundStyle(.yellow)
                    .padding(6).background(.black)
            }
        if sessionPreview {
            try await render(view, width: 1024, height: 640, to: output.appendingPathComponent("sessions-populated.png"))
            model.selectScope(projectID: projects[1].id, session: ProjectSession.generalID(for: projects[1].id))
            workspace.selectedID = projects[1].id
            try await render(view, width: 820, height: 560, to: output.appendingPathComponent("sessions-empty.png"))
            return
        }
        if responsive {
            try await verifyComposerDestination(view, workspace: workspace, model: model, projects: projects)
            let layouts: [(CGFloat, CGFloat)] = [(820, 560), (1024, 640), (1280, 800), (1440, 900), (1920, 1080)]
            for (width, height) in layouts {
                let size = "\(Int(width))x\(Int(height))"
                model.selectProject(projects[0].id)
                workspace.selectedID = projects[0].id
                for mode in [WorkspaceNavigationMode.board, .list, .grid] {
                    model.showOverview(mode)
                    try await render(view, width: width, height: height,
                                     to: output.appendingPathComponent("responsive-\(mode.rawValue)-\(size).png"),
                                     expectedEditor: "task-composer-editor")
                }
                model.open(agents[1])
                try await render(view, width: width, height: height,
                                 to: output.appendingPathComponent("responsive-agent-\(size).png"),
                                 expectedEditor: "agent-prompt-editor")
            }
            model.selectProject(projects[0].id)
            workspace.selectedID = projects[0].id
            model.showOverview(.board)
            model.error = "Falha simulada de atualização: verifique a conexão local, preserve o rascunho e tente novamente."
            var failingInspection = inspection
            failingInspection["engine"] = "fixture-error"
            try JSONSerialization.data(withJSONObject: failingInspection).write(to: root.appendingPathComponent("inspect.json"))
            await model.loadProviders()
            try await render(view, width: 820, height: 560,
                             to: output.appendingPathComponent("responsive-errors-820x560.png"),
                             expectedEditor: "task-composer-editor")
            model.error = nil
            try JSONSerialization.data(withJSONObject: inspection).write(to: root.appendingPathComponent("inspect.json"))
            await model.loadProviders()
            let fixtureSkills = try await client.skills(kind: "claude", cwd: projects[0].path)
            guard fixtureSkills.count == 12 else { throw NSError(domain: "ResponsivePreview", code: 13) }
            model.projectTaskDrafts[projects[0].id] = "/"
            try await render(view, width: 820, height: 560,
                             to: output.appendingPathComponent("responsive-skills-820x560.png"),
                             expectedEditor: "task-composer-editor")
            model.projectTaskDrafts[projects[0].id] = "Prévia com dados fictícios: revisar os caminhos longos."
            let wideSidebar = WorkspaceView(workspace: workspace, live: model, preferredSidebarWidth: 380)
                .environment(\.scenePhase, .active) // Offscreen fixtures have no active native scene.
                .preferredColorScheme(.dark).tint(TerminalTheme.accent)
                .overlay(alignment: .bottomTrailing) {
                    Text("Prévia · dados fictícios").font(.system(size: 10)).foregroundStyle(.yellow).padding(6).background(.black)
                }
            for (width, height) in [(CGFloat(820), CGFloat(560)), (CGFloat(1024), CGFloat(640))] {
                model.selectProject(projects[0].id)
                workspace.selectedID = projects[0].id
                model.showOverview(.board)
                try await render(wideSidebar, width: width, height: height,
                                 to: output.appendingPathComponent("responsive-wide-sidebar-board-\(Int(width))x\(Int(height)).png"),
                                 expectedEditor: "task-composer-editor")
                model.open(agents[1])
                try await render(wideSidebar, width: width, height: height,
                                 to: output.appendingPathComponent("responsive-wide-sidebar-agent-\(Int(width))x\(Int(height)).png"),
                                 expectedEditor: "agent-prompt-editor")
            }
            workspace.showsDemo = true
            try await render(view, width: 820, height: 560, to: output.appendingPathComponent("responsive-demo-820x560.png"))
            try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("responsive-demo-1440x900.png"))
            workspace.showsDemo = false
            try JSONSerialization.data(withJSONObject: auditReports, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("responsive-layouts.json"))
            print("Matriz responsiva: \(auditReports.count) layouts nativos com editores dentro dos limites")
            return
        }
        model.selectScope(projectID: projects[0].id, session: sessionName)
        workspace.selectedID = projects[0].id
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("project-sidebar.png"))
        try await render(view, width: 820, height: 560, to: output.appendingPathComponent("project-sidebar-compact.png"))
        model.selectScope(projectID: nil, session: nil)
        workspace.selectedID = nil
        model.showOverview(.list)
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("weaver-overview.png"))
        try await render(view, width: 820, height: 560, to: output.appendingPathComponent("weaver-overview-compact.png"))
        model.showOverview(.board)
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("octo-native-board.png"))
        try await render(view, width: 820, height: 560, to: output.appendingPathComponent("octo-native-compact.png"))
        model.showOverview(.list)
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("octo-native-list.png"))
        model.terminalPreviewDensity = .economical
        model.showOverview(.grid)
        try await render(view, width: 820, height: 560, to: output.appendingPathComponent("memory-grid-two-compact.png"), settleDelay: .milliseconds(1000))
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("memory-grid-two.png"), settleDelay: .milliseconds(1000))
        let beforeGrid = try String(contentsOf: root.appendingPathComponent("operations.txt"), encoding: .utf8)
        model.terminalPreviewDensity = .full
        model.showOverview(.grid)
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("octo-native-grid.png"), settleDelay: .milliseconds(1000))
        let afterGrid = try String(contentsOf: root.appendingPathComponent("operations.txt"), encoding: .utf8)
        let gridOps = String(afterGrid.dropFirst(beforeGrid.count)).split(separator: "\n").map(String.init)
        guard gridOps.allSatisfy({ ["list", "snapshot"].contains($0) }),
              gridOps.filter({ $0 == "snapshot" }).count == min(6, agents.count) else {
            throw NSError(domain: "Preview", code: 4, userInfo: [NSLocalizedDescriptionKey: "Grid sent unexpected operations"])
        }
        print("Grid fixture operations: " + gridOps.joined(separator: ", "))
        model.open(agents[1])
        try await render(view, width: 1440, height: 900, to: output.appendingPathComponent("octo-native-agent.png"))
        let firstRunRepository = ProjectRepository(fileURL: root.appendingPathComponent("first-run.json"))
        try JSONEncoder().encode(EngineSessionList(agents: [], sessions: ["default"]))
            .write(to: root.appendingPathComponent("list.json"))
        await model.refresh()
        model.showOverview(.board)
        let firstRun = WorkspaceModel(repository: firstRunRepository)
        let emptyView = WorkspaceView(workspace: firstRun, live: model)
            .environment(\.scenePhase, .active) // Offscreen fixtures have no active native scene.
            .preferredColorScheme(.dark).tint(TerminalTheme.accent)
            .overlay(alignment: .bottomTrailing) {
                Text("Prévia · dados fictícios").font(.system(size: 10)).foregroundStyle(.yellow).padding(6).background(.black)
            }
        try await render(emptyView, width: 820, height: 560, to: output.appendingPathComponent("octo-native-empty.png"))
        let corruptURL = root.appendingPathComponent("corrupt-projects.json")
        try Data("invalid fixture".utf8).write(to: corruptURL)
        let failed = WorkspaceModel(repository: ProjectRepository(fileURL: corruptURL))
        let failedView = WorkspaceView(workspace: failed, live: model)
            .environment(\.scenePhase, .active) // Offscreen fixtures have no active native scene.
            .preferredColorScheme(.dark).tint(TerminalTheme.accent)
        try await render(failedView, width: 820, height: 560, to: output.appendingPathComponent("octo-native-storage-error.png"))
        guard try Data(contentsOf: corruptURL) == Data("invalid fixture".utf8) else {
            throw NSError(domain: "Preview", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid fixture store was changed"])
        }
        print("Prévia gerada com fixture isolado: " + output.path)
    }

    @MainActor static var auditReports: [[String: Any]] = []

    /// Exercise the actual SwiftUI onChange and editor binding, without starting an agent.
    @MainActor static func verifyComposerDestination<V: View>(_ view: V, workspace: WorkspaceModel,
                                                              model: LiveWorkspaceModel, projects: [Project]) async throws {
        let destination = projects[0].id
        let filter = projects[1].id
        let original = model.projectTaskDrafts[destination] ?? ""
        let otherDraft = model.projectTaskDrafts[filter]
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        model.selectProject(filter)
        workspace.selectedID = filter
        try await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        guard let editor = descendants(hosting).compactMap({ $0 as? NSTextView })
            .first(where: { $0.accessibilityIdentifier() == "task-composer-editor" }), editor.string == original else {
            throw NSError(domain: "ResponsivePreview", code: 14, userInfo: [NSLocalizedDescriptionKey: "Filtro trocou o rascunho de destino"])
        }
        editor.insertText("\nDestino preservado", replacementRange: NSRange(location: (original as NSString).length, length: 0))
        guard model.projectTaskDrafts[destination] == original + "\nDestino preservado",
              model.projectTaskDrafts[filter] == otherDraft else {
            throw NSError(domain: "ResponsivePreview", code: 15, userInfo: [NSLocalizedDescriptionKey: "Filtro redirecionou a edição para outro projeto"])
        }
        model.projectTaskDrafts[destination] = original
        model.selectProject(destination)
        workspace.selectedID = destination
        print("Filtro de projeto preserva destino e rascunho do compositor")
    }

    @MainActor static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL,
                                          expectedEditor: String? = nil, settleDelay: Duration = .milliseconds(600)) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settleDelay)
        hosting.layoutSubtreeIfNeeded()
        guard abs(hosting.bounds.width - width) <= 1, abs(hosting.bounds.height - height) <= 1 else {
            throw NSError(domain: "ResponsivePreview", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "Janela excedeu o tamanho solicitado: " + url.lastPathComponent + " " + NSStringFromRect(hosting.bounds)])
        }
        if let expectedEditor {
            let editors = descendants(hosting).compactMap { $0 as? NSTextView }
            guard let editor = editors.first(where: { $0.accessibilityIdentifier() == expectedEditor }),
                  let scroll = editor.enclosingScrollView else {
                throw NSError(domain: "ResponsivePreview", code: 10, userInfo: [NSLocalizedDescriptionKey: "Editor ausente: " + expectedEditor])
            }
            let rect = hosting.convert(scroll.bounds, from: scroll)
            guard rect.width > 20, rect.height >= 40, hosting.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                  !scroll.hasVerticalScroller, !scroll.hasHorizontalScroller else {
                throw NSError(domain: "ResponsivePreview", code: 11, userInfo: [NSLocalizedDescriptionKey: "Editor fora dos limites: " + NSStringFromRect(rect)])
            }
            let identifiers = expectedEditor == "task-composer-editor"
                ? ["task-composer-provider", "task-composer-folder", "task-composer-options", "task-composer-start"]
                : ["agent-prompt-send"]
            let nodes = accessibilityDescendants(hosting)
            var controls: [[String: Any]] = []
            for identifier in identifiers {
                guard let node = nodes.first(where: { $0.accessibilityIdentifier() == identifier }) else { continue }
                let controlRect = hosting.convert(window.convertFromScreen(node.accessibilityFrame()), from: nil)
                guard controlRect.width > 0, controlRect.height > 0 else { continue }
                guard hosting.bounds.insetBy(dx: -1, dy: -1).contains(controlRect) else {
                    throw NSError(domain: "ResponsivePreview", code: 12, userInfo: [NSLocalizedDescriptionKey: "Controle fora da janela: " + identifier + " " + NSStringFromRect(controlRect)])
                }
                controls.append(["id": identifier, "x": controlRect.minX, "y": controlRect.minY,
                                 "width": controlRect.width, "height": controlRect.height])
            }
            auditReports.append(["file": url.lastPathComponent, "width": width, "height": height,
                                 "editor": expectedEditor, "x": rect.minX, "y": rect.minY,
                                 "editorWidth": rect.width, "editorHeight": rect.height, "scrollers": false,
                                 "controls": controls])
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "Preview", code: 2)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 3) }
        try data.write(to: url)
        window.contentView = nil
    }

    @MainActor static func accessibilityDescendants(_ root: any NSAccessibilityProtocol, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 40 else { return [] }
        return [root] + (root.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .flatMap { accessibilityDescendants($0, depth: depth + 1) }
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
