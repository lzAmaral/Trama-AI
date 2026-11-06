import AppKit
import SwiftUI
import SwiftTerm

/// Native VT terminal presentation. The engine owns the PTY and all process lifecycle.
/// `onResize` receives rows first, then columns. Supply a new view identity per session.
/// Snapshots replace the visible screen; they are not appended as a transcript.
struct NativeTerminalView: NSViewRepresentable {
    let snapshot: Data
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero,
                                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                options: TerminalOptions(scrollback: 0))
        view.nativeBackgroundColor = NSColor(red: 17 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 229 / 255, green: 231 / 255, blue: 235 / 255, alpha: 1)
        view.terminalDelegate = context.coordinator
        view.setAccessibilityLabel("Terminal do agente")
        context.coordinator.apply(snapshot, to: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.apply(snapshot, to: view)
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        view.terminalDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var onInput: (Data) -> Void
        var onResize: (Int, Int) -> Void
        private var lastSnapshot: Data?
        private var applyingSnapshot = false
        private var lastSize: (cols: Int, rows: Int)?

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func apply(_ snapshot: Data, to view: TerminalView) {
            guard snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            applyingSnapshot = true
            defer { applyingSnapshot = false }
            // Each upstream snapshot assumes a fresh normal screen. Alternate snapshots
            // enter 1049 explicitly, but normal snapshots do not leave it. Mouse modes
            // are also emitted relative to defaults, so previously enabled tracking or
            // encoding must be cleared before replay. Cursor/keypad/paste/SGR state is
            // explicitly reproduced by vt100::Screen.state_formatted().
            // Keep terminal dimensions and suppress generated replies during replay.
            view.feed(text: "\u{1b}[?1049l"
                      + "\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l"
                      + "\u{1b}[?1005l\u{1b}[?1006l"
                      + "\u{1b}[0m\u{1b}[H\u{1b}[2J")
            view.feed(byteArray: Array(snapshot)[...])
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !applyingSnapshot, newCols >= 10, newRows >= 2,
                  lastSize?.cols != newCols || lastSize?.rows != newRows else { return }
            lastSize = (newCols, newRows)
            lastSnapshot = nil
            // A layout callback must not synchronously mutate the enclosing SwiftUI view.
            let callback = onResize
            Task { @MainActor in callback(newRows, newCols) }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !applyingSnapshot else { return }
            onInput(Data(data))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}

        // Terminal output cannot read/write the clipboard, open URLs, or trigger host actions.
        // User-initiated native copy/paste remains handled by TerminalView itself.
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
