import AppKit
import SwiftUI
import TramaCore

/// Original Trama mascot, generated for this project and approved by the user.
struct TramaWeaver: View {
    // SwiftPM's macOS accessor searches beside the executable/build tree; packaged
    // apps keep resource bundles in Contents/Resources instead.
    static let resourceBundle = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("Trama_TramaApp.bundle")) } ?? .module
    static let image = resourceBundle.url(forResource: "trama-weaver", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var size: CGFloat = 112
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

struct OverviewMetric: Identifiable {
    let title: String
    let count: Int
    let color: Color
    var id: String { title }
}

/// Counts describe the same visible records as the list, including unusual/offline states.
struct WorkspaceOverviewHeader<Usage: View>: View {
    let metrics: [OverviewMetric]
    @ViewBuilder let usage: () -> Usage
    @State private var showsUsage = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 28) {
                identity(size: 124)
                Rectangle().fill(TerminalTheme.border).frame(width: 1, height: 104)
                usage().frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                identity(size: 72, compact: true)
                Spacer(minLength: 0)
                Button { showsUsage = true } label: {
                    Label("Consumo", systemImage: "chart.bar")
                        .font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.accent)
                }.buttonStyle(.plain)
                    .popover(isPresented: $showsUsage) { usage().padding(20).frame(width: 360) }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.bottom, 8)
    }

    private func identity(size: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: 16) {
            TramaWeaver(size: size)
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                ForEach(metrics) { metric in
                    HStack(spacing: 10) {
                        Text("\(metric.count)").font(TerminalTheme.mono(compact ? 10 : 12, weight: .bold))
                            .foregroundStyle(TerminalTheme.accentInk)
                            .frame(width: compact ? 24 : 30, height: compact ? 15 : 21).background(metric.color)
                        Text(metric.title).font(TerminalTheme.mono(compact ? 10 : 12)).foregroundStyle(TerminalTheme.secondary)
                    }.accessibilityElement(children: .combine)
                }
            }.fixedSize()
        }.fixedSize()
    }
}

struct WorkspaceUsageSummary: View {
    let snapshots: [String: EngineUsage]
    let providers: [EngineProvider]
    let onConsult: (EngineProvider) -> Void
    let onInspect: () -> Void

    private let supported: Set<String> = ["claude", "codex", "kilo", "opencode", "antigravity", "grok", "kimi"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("consumo").foregroundStyle(TerminalTheme.primary)
                Text("· manual").foregroundStyle(TerminalTheme.muted)
                Spacer(minLength: 8)
                Menu {
                    ForEach(providers.filter { supported.contains($0.id) && $0.installed }) { provider in
                        Button(provider.id) { onConsult(provider) }
                    }
                    Divider()
                    Button("Motor e provedores…", action: onInspect)
                } label: { Text(snapshots.isEmpty ? "consultar" : "atualizar").foregroundStyle(TerminalTheme.accent) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Consultar consumo manualmente")
            }.font(TerminalTheme.mono(11))
            if snapshots.isEmpty {
                Text("Consulte um provedor para exibir seus limites.")
                    .font(TerminalTheme.mono(11)).foregroundStyle(TerminalTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nenhuma consulta automática")
                    .font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshots.keys.sorted(), id: \.self) { kind in
                            if let usage = snapshots[kind] {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(kind).foregroundStyle(TerminalTheme.providerColor(kind))
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: Double(usage.updatedAtMs) / 1000), format: .dateTime.hour().minute())
                                            .foregroundStyle(TerminalTheme.muted)
                                            .help("Horário da última consulta manual")
                                    }
                                    if let limits = usage.limits {
                                        if let window = limits.session { quota("Janela", window) }
                                        if let window = limits.weekly { quota("Semana", window) }
                                        if let window = limits.monthly { quota("Mês", window) }
                                        if let credits = limits.credits { Text("Saldo: \(credits, specifier: "%.2f")") }
                                        if limits.session == nil && limits.weekly == nil && limits.monthly == nil && limits.credits == nil {
                                            Text("Nenhum limite retornado").foregroundStyle(TerminalTheme.secondary)
                                        }
                                    }
                                    if let problem = usage.problem {
                                        Text(problem).foregroundStyle(TerminalTheme.warning)
                                            .lineLimit(2).help(problem)
                                    } else if usage.limits == nil {
                                        Text("Limites indisponíveis").foregroundStyle(TerminalTheme.secondary)
                                    }
                                }
                            }
                        }
                    }
                }.frame(height: 96)
            }
        }.font(TerminalTheme.mono(11))
    }

    private func quota(_ title: String, _ window: EngineUsageWindow) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(TerminalTheme.secondary).frame(width: 52, alignment: .leading)
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .tint(window.usedPercent >= 90 ? TerminalTheme.danger : window.usedPercent >= 70 ? TerminalTheme.warning : TerminalTheme.positive)
                .frame(maxWidth: .infinity)
            Text("\(window.usedPercent, specifier: "%.0f")%")
                .foregroundStyle(TerminalTheme.primary).frame(width: 38, alignment: .trailing)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title): \(window.usedPercent, specifier: "%.0f") por cento usado")
            .help(window.resetsAtMs.map { "Renova em " + Date(timeIntervalSince1970: Double($0) / 1000).formatted() } ?? "Renovação não informada")
    }
}

struct TerminalListHeading: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("AGENTE / TAREFA").frame(width: 250, alignment: .leading)
            Text("TEMPO").frame(width: 70, alignment: .leading)
            Text("PROVEDOR").frame(width: 84, alignment: .leading)
            Text("ATIVIDADE").frame(maxWidth: .infinity, alignment: .leading)
        }.font(TerminalTheme.mono(11, weight: .semibold)).foregroundStyle(TerminalTheme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 10)
        TerminalRule()
    }
}

struct TerminalAgentRow: View {
    let number: String
    let name: String
    let state: String
    let elapsed: String
    let provider: String
    let activity: String
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(number).foregroundStyle(TerminalTheme.muted).frame(width: 26, alignment: .trailing)
                    Image(systemName: liveStateSymbol(state)).foregroundStyle(liveStateColor(state)).frame(width: 14)
                    Text(name).foregroundStyle(state == "done" || state == "paused" || state == "lost" ? liveStateColor(state) : TerminalTheme.primary)
                        .lineLimit(1).truncationMode(.middle)
                }.frame(width: 250, alignment: .leading)
                Text(elapsed).foregroundStyle(TerminalTheme.muted).frame(width: 70, alignment: .leading)
                    .help("Tempo desde a criação do registro")
                Text(provider).foregroundStyle(TerminalTheme.providerColor(provider)).frame(width: 84, alignment: .leading)
                Text(activity).foregroundStyle(state == "paused" || state == "lost" ? liveStateColor(state) : TerminalTheme.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.font(TerminalTheme.mono(12)).padding(.horizontal, 8).padding(.vertical, 7)
                .contentShape(Rectangle()).background(hovered ? TerminalTheme.raised : .clear)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help("\(name) · \(liveStateTitle(state))\n\(activity)")
            .accessibilityLabel("Abrir \(name), agente \(number), \(provider), \(liveStateTitle(state)), \(activity)")
    }
}
