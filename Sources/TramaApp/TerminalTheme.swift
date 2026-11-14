import SwiftUI

/// Native translation of Octo's desktop tokens (MIT), reference 1dc08a44.
/// Origin and retained license: ThirdPartyNotices/Octo-MIT.txt.
enum TerminalTheme {
    static let background = rgb(0x000000)
    static let sidebar = rgb(0x000000)
    static let surface = rgb(0x0a0b0c)
    static let raised = rgb(0x141718)
    static let primary = rgb(0xececf2)
    static let secondary = rgb(0x9a9aa8)
    static let muted = rgb(0x80808e)
    static let accent = rgb(0x35fddc)
    static let accentInk = rgb(0x04201c)
    static let warning = rgb(0xf0d65a)
    static let positive = rgb(0x50d782)
    static let danger = rgb(0xf04e5c)
    static let border = rgb(0x1a1d1f)
    static let strongBorder = rgb(0x23282a)
    static let waitingSurface = rgb(0x1a1911)

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }

    static func providerColor(_ kind: String) -> Color {
        switch kind {
        case "claude": rgb(0xde805c)
        case "codex": rgb(0x78afff)
        case "kilo": rgb(0xece26e)
        case "opencode": rgb(0xfab283)
        case "antigravity": rgb(0x9696ff)
        case "grok": rgb(0xe8e8f0)
        case "qwen": rgb(0xba8cff)
        case "kimi": rgb(0xec80dc)
        case "pi": rgb(0xaadc5a)
        case "cursor": rgb(0xd6c4a0)
        case "terminal": rgb(0x5ad2d2)
        default: secondary
        }
    }

    static func projectColor(_ path: String) -> Color {
        let colors: [UInt32] = [0x8ce2d6, 0x9696ff, 0xec80a0, 0xaadc5a, 0x89bafa, 0xfab283]
        let value = path.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return rgb(colors[Int(value % UInt64(colors.count))])
    }
}

struct WorkspaceCardStyle: ButtonStyle {
    var state: String? = nil
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(state == "paused" ? TerminalTheme.waitingSurface :
                        (hovered || configuration.isPressed ? TerminalTheme.raised : TerminalTheme.surface),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(state == "paused" ? TerminalTheme.warning.opacity(0.45) :
                        (state == "lost" ? TerminalTheme.danger.opacity(0.4) :
                        (hovered ? TerminalTheme.strongBorder : TerminalTheme.border))))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}

struct NativeActionButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TerminalTheme.ui(13, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 32)
            .foregroundStyle(primary ? TerminalTheme.accentInk : TerminalTheme.primary)
            .background(primary ? TerminalTheme.accent : (hovered ? TerminalTheme.raised : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? .clear : TerminalTheme.border))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { hovered = $0 }
    }
}

struct WorkspaceChipStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TerminalTheme.mono(12))
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovered || configuration.isPressed ? TerminalTheme.strongBorder : TerminalTheme.raised,
                        in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

struct ShortcutHint: View {
    let text: String
    var body: some View {
        Text(text).font(TerminalTheme.mono(10)).foregroundStyle(TerminalTheme.muted)
            .accessibilityHidden(true)
    }
}

struct TerminalRule: View {
    var body: some View {
        Rectangle().fill(TerminalTheme.border).frame(height: 1).accessibilityHidden(true)
    }
}
