import SwiftUI

enum TerminalTheme {
    static let background = Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255)
    static let sidebar = Color(red: 14 / 255, green: 15 / 255, blue: 17 / 255)
    static let surface = Color(red: 23 / 255, green: 25 / 255, blue: 28 / 255)
    static let primary = Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255)
    static let secondary = Color(red: 161 / 255, green: 166 / 255, blue: 173 / 255)
    static let accent = Color(red: 155 / 255, green: 206 / 255, blue: 165 / 255)
    static let warning = Color(red: 219 / 255, green: 190 / 255, blue: 126 / 255)
    static let border = Color.white.opacity(0.10)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct TerminalRule: View {
    var body: some View {
        Rectangle().fill(TerminalTheme.border).frame(height: 1)
    }
}
