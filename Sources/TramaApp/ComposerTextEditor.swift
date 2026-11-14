import AppKit
import SwiftUI

/// A local, plain-text AppKit editor. Scrolling stays available without a legacy scroller track.
/// NSTextView owns text input, marked text, selection, undo and standard editing shortcuts.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEditable = true
    var fontSize: CGFloat = 14
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @Environment(\.isEnabled) private var isEnabled

    private var canEdit: Bool { isEditable && isEnabled }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none

        let editor = ComposerInputTextView(frame: NSRect(x: 0, y: 0, width: 0, height: fontSize + 12))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        context.coordinator.observeUndo(editor)
        editor.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        editor.didAttachToWindow = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.synchronizeFocus(editor)
        }
        scrollView.documentView = editor
        configure(editor, coordinator: context.coordinator)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        guard let editor = scrollView.documentView as? ComposerInputTextView else { return }
        editor.delegate = nil
        editor.focusChanged = nil
        editor.didAttachToWindow = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ComposerInputTextView else { return }
        context.coordinator.parent = self
        configure(editor, coordinator: context.coordinator)
    }

    private func configure(_ editor: ComposerInputTextView, coordinator: Coordinator) {
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize) }
        editor.textColor = NSColor(TerminalTheme.primary)
        editor.insertionPointColor = NSColor(TerminalTheme.accent)
        if editor.isEditable != canEdit { editor.isEditable = canEdit }
        editor.isSelectable = true
        let minimumHeight = max(fontSize + 12, editor.enclosingScrollView?.contentSize.height ?? 0)
        editor.minSize = NSSize(width: 0, height: minimumHeight)
        if editor.frame.height < minimumHeight {
            editor.setFrameSize(NSSize(width: editor.frame.width, height: minimumHeight))
        }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityIdentifier(accessibilityIdentifier)
        // Reapplying identical text would reset the insertion point and undo/IME state.
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRanges
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            editor.string = text
            let count = (text as NSString).length
            editor.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let location = min(range.location, count)
                return NSValue(range: NSRange(location: location, length: min(range.length, count - location)))
            }
        }
        coordinator.synchronizeFocus(editor)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        private var undoObservers: [NSObjectProtocol] = []
        private var active = true

        func invalidate() {
            active = false
            stopObservingUndo()
        }

        func observeUndo(_ editor: NSTextView) {
            stopObservingUndo()
            guard let manager = editor.undoManager else { return }
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self, weak editor] _ in
                    Task { @MainActor in
                        guard let self, self.active, let editor, editor.delegate === self else { return }
                        if self.parent.text != editor.string { self.parent.text = editor.string }
                    }
                })
            }
        }

        func stopObservingUndo() {
            for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
            undoObservers.removeAll()
        }

        init(_ parent: ComposerTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
        }

        func focusChanged(_ focused: Bool) {
            // AppKit may change focus during a SwiftUI update; publish after that update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                if self.parent.isFocused != focused { self.parent.isFocused = focused }
            }
        }

        fileprivate func synchronizeFocus(_ editor: ComposerInputTextView) {
            guard active, parent.isFocused && parent.canEdit, editor.window?.firstResponder !== editor else { return }
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, self.active, let editor, self.parent.isFocused, self.parent.canEdit,
                      let window = editor.window, window.firstResponder !== editor else { return }
                window.makeFirstResponder(editor)
            }
        }
    }
}

/// Keeps focus callbacks and undo local without replacing NSTextView's input or key handling.
private final class ComposerInputTextView: NSTextView {
    private let localUndoManager = UndoManager()
    override var undoManager: UndoManager? { localUndoManager }
    var focusChanged: ((Bool) -> Void)?
    var didAttachToWindow: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { didAttachToWindow?() }
    }
}
