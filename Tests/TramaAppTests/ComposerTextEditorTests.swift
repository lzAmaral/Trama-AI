import AppKit
import SwiftUI
import Testing
@testable import TramaApp

@MainActor
@Suite(.serialized)
struct ComposerTextEditorTests {
    private final class Draft {
        var text: String
        var focused = false
        init(_ text: String) { self.text = text }
    }

    private func view(_ draft: Draft, editable: Bool = true) -> ComposerTextEditor {
        ComposerTextEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                           isFocused: Binding(get: { draft.focused }, set: { draft.focused = $0 }),
                           isEditable: editable, accessibilityLabel: "Editor de teste",
                           accessibilityIdentifier: "test-composer-editor")
    }

    private func findEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap(findEditor).first
    }

    @Test func multilineUnicodeEditingUpdatesTheDraftWithoutLegacyScrollers() async throws {
        let draft = Draft("ação 👩🏽‍💻\nsegunda linha")
        let hosting = NSHostingView(rootView: view(draft))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let editor = try #require(findEditor(hosting))
        let scroll = try #require(editor.enclosingScrollView)
        #expect(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(editor.string == draft.text)
        #expect(editor.allowsUndo && !editor.isRichText)
        editor.insertText("\n\"texto literal\" — fim", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(draft.text == "ação 👩🏽‍💻\nsegunda linha\n\"texto literal\" — fim")
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
    }

    @Test func repeatedUpdatesKeepSelectionAndExternalDraftsClampItSafely() async throws {
        let draft = Draft("Texto de trabalho")
        let hosting = NSHostingView(rootView: view(draft))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let editor = try #require(findEditor(hosting))
        editor.setSelectedRange(NSRange(location: 9, length: 4))
        hosting.rootView = view(draft)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.selectedRange() == NSRange(location: 9, length: 4))
        draft.text = "oi"
        hosting.rootView = view(draft, editable: false)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.string == "oi")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
        #expect(!editor.isEditable)
    }

    @Test func undoRedoWorksLocallyAndExternalDraftReplacementClearsOnlyItsHistory() async throws {
        let first = Draft("Tarefa")
        let second = Draft("Outra")
        let hosting = NSHostingView(rootView: view(first))
        let other = NSHostingView(rootView: view(second))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        other.frame = hosting.frame
        hosting.layoutSubtreeIfNeeded(); other.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let editor = try #require(findEditor(hosting))
        let otherEditor = try #require(findEditor(other))
        editor.insertText(" nova", replacementRange: NSRange(location: 6, length: 0))
        otherEditor.insertText(" preservada", replacementRange: NSRange(location: 5, length: 0))
        editor.breakUndoCoalescing(); otherEditor.breakUndoCoalescing()
        let undo = try #require(editor.undoManager)
        let otherUndo = try #require(otherEditor.undoManager)
        try await Task.sleep(for: .milliseconds(30))
        #expect(undo !== otherUndo)
        #expect(undo.canUndo && otherUndo.canUndo)
        undo.undo()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.string == "Tarefa")
        #expect(first.text == "Tarefa")
        undo.redo()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.string == "Tarefa nova")
        first.text = ""
        hosting.rootView = view(first)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.string.isEmpty)
        #expect(!undo.canUndo && !undo.canRedo)
        #expect(otherUndo.canUndo)
        otherUndo.undo()
        try await Task.sleep(for: .milliseconds(30))
        #expect(otherEditor.string == "Outra")
    }

    @Test func anExternalRefreshDoesNotReplaceAnActiveIMEComposition() async throws {
        let draft = Draft("")
        let hosting = NSHostingView(rootView: view(draft))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let editor = try #require(findEditor(hosting))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.hasMarkedText())
        let composingText = editor.string
        draft.text = "Atualização externa"
        hosting.rootView = view(draft)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.hasMarkedText())
        #expect(editor.string == composingText)
        editor.unmarkText()
    }
}
