import Foundation
import SwiftUI
import TramaCore

@MainActor
final class LiveWorkspaceModel: ObservableObject {
    let client = OctoEngineClient(executableURL: OctoEngineClient.defaultExecutableURL,
                                 homeURL: OctoEngineClient.defaultHomeURL, timeout: 30)
    @Published var agents: [EngineAgent] = []
    @Published var sessions: [String] = []
    @Published var providers: [EngineProvider] = []
    @Published var error: String?
    @Published var connectionError: String?
    @Published var busy = false
    @Published var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await client.listSessions()
            try Task.checkCancellation()
            agents = result.agents
            sessions = result.sessions
            connectionError = nil
        } catch is CancellationError { } catch {
            self.connectionError = error.localizedDescription
        }
    }

    func loadProviders() async {
        do { providers = try await client.inspect().providers.filter(\.installed) }
        catch { self.connectionError = error.localizedDescription }
    }

    func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await operation()
            await refresh()
        } catch is CancellationError {
            error = "Operação interrompida. Atualize o quadro antes de tentar novamente; a sessão pode ter sido criada."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LiveWorkspaceView: View {
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    @StateObject private var model = LiveWorkspaceModel()
    @State private var search = ""
    @State private var session = ""
    @State private var listMode = false
    @State private var showsComposer = false
    @State private var selectedAgent: EngineAgent?
    @State private var showsNewSession = false
    @State private var newSession = ""
    private let states = ["paused", "working", "done", "idle", "lost", "exited"]

    private var filtered: [EngineAgent] {
        let path = projects.first { $0.id == selectedProjectID }?.path
        return model.agents.filter { agent in
            (path == nil || URL(fileURLWithPath: agent.project).standardizedFileURL.resolvingSymlinksInPath().path == path) &&
            (session.isEmpty || agent.session == session) &&
            (search.isEmpty || [agent.name, agent.task, agent.kind, agent.project].contains { $0.localizedStandardContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            TerminalRule()
            if let error = model.error ?? model.connectionError {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled)
                    Spacer()
                    if model.error != nil { Button("Dispensar") { model.error = nil } }
                    Button("Atualizar") { Task { await model.refresh() } }.disabled(model.refreshing)
                }.padding(16)
            }
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("[info] Nenhuma sessão neste filtro").foregroundStyle(TerminalTheme.accent)
                    Text(projects.isEmpty ? "Adicione uma pasta na barra lateral para iniciar uma tarefa." : "Inicie uma tarefa para acompanhar agentes reais neste quadro.")
                        .foregroundStyle(TerminalTheme.secondary)
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else if listMode {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { agent in card(agent) }
                    }.padding(20)
                }
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(states, id: \.self) { state in
                                let items = filtered.filter { $0.state == state }
                                if !items.isEmpty || !["lost", "exited"].contains(state) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Text(liveStateTitle(state)).foregroundStyle(liveStateColor(state))
                                            Spacer()
                                            Text("\(items.count)").foregroundStyle(TerminalTheme.secondary)
                                        }
                                        if items.isEmpty { Text("Sem agentes").foregroundStyle(TerminalTheme.secondary) }
                                        ForEach(items) { agent in card(agent) }
                                    }.frame(width: max(240, (geometry.size.width - 88) / 4))
                                }
                            }
                            let unknown = filtered.filter { !states.contains($0.state) }
                            if !unknown.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Estado desconhecido")
                                    ForEach(unknown) { agent in card(agent) }
                                }.frame(width: 240)
                            }
                        }.padding(20)
                    }
                }
            }
            TerminalRule()
            Text("Sessões reais · fechar a janela não encerra os processos")
                .foregroundStyle(TerminalTheme.secondary).padding(12)
        }
        .font(TerminalTheme.mono(12))
        .foregroundStyle(TerminalTheme.primary)
        .background(TerminalTheme.background)
        .task {
            await model.loadProviders()
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .sheet(isPresented: $showsComposer) {
            NewAgentView(model: model, projects: projects, initialProjectID: selectedProjectID, initialSession: session)
        }
        .sheet(item: $selectedAgent) { agent in
            LiveAgentDetail(model: model, agentID: agent.id, initial: agent)
        }
        .alert("Nova sessão", isPresented: $showsNewSession) {
            TextField("Nome da sessão", text: $newSession)
            Button("Cancelar", role: .cancel) { }
            Button("Criar") {
                let name = newSession
                Task { await model.perform { try await model.client.createSession(name: name) } }
            }
        } message: { Text("Agrupe tarefas e agentes em uma sessão do motor.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("trama > sessões").font(TerminalTheme.mono(24, weight: .medium))
                Spacer()
                Button("Nova tarefa", systemImage: "plus") { showsComposer = true }
                    .disabled(projects.isEmpty || model.busy)
            }
            Text("\(filtered.count) agentes · \(filtered.filter { $0.state == "paused" }.count) precisam de você")
                .foregroundStyle(TerminalTheme.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { filters; searchField }
                VStack { filters; searchField }
            }
        }
    }

    private var filters: some View {
        HStack {
            Picker("Sessão", selection: $session) {
                Text("Todas as sessões").tag("")
                ForEach(model.sessions, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 180)
            Button("+ sessão") { newSession = ""; showsNewSession = true }.disabled(model.busy)
            Picker("Visualização", selection: $listMode) {
                Text("Quadro").tag(false)
                Text("Lista").tag(true)
            }.pickerStyle(.segmented).frame(width: 140)
        }
    }

    private var searchField: some View {
        TextField("Buscar tarefa, projeto ou provedor", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 160)
    }

    private func card(_ agent: EngineAgent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(agent.name).font(TerminalTheme.mono(13, weight: .semibold))
                Spacer()
                Text("#\(agent.id)").foregroundStyle(TerminalTheme.secondary)
            }
            Text("\(agent.kind) · \(agent.session)").foregroundStyle(TerminalTheme.accent)
            Text(URL(fileURLWithPath: agent.project).lastPathComponent).foregroundStyle(TerminalTheme.secondary)
            if let branch = agent.branch { Text(branch).foregroundStyle(TerminalTheme.secondary) }
            Text(liveStateTitle(agent.state)).foregroundStyle(liveStateColor(agent.state))
            Text(agent.activity.isEmpty ? agent.task : agent.activity).lineLimit(5)
                .foregroundStyle(TerminalTheme.secondary)
            Button("Abrir agente") { selectedAgent = agent }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalTheme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(agent.state == "paused" ? TerminalTheme.warning : TerminalTheme.border))
    }
}

func liveStateTitle(_ state: String) -> String {
    switch state {
    case "paused": "Precisa de você"
    case "working": "Em andamento"
    case "done": "Concluído"
    case "idle": "Disponível"
    case "lost": "Interrompido"
    case "exited": "Encerrado"
    default: "Desconhecido: \(state)"
    }
}

func liveStateColor(_ state: String) -> Color {
    switch state {
    case "paused", "lost": TerminalTheme.warning
    case "done": TerminalTheme.accent
    default: TerminalTheme.secondary
    }
}
