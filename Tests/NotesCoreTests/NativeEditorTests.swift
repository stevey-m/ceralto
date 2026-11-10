import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct NativeEditorTests {
    @Test func nativeTypingFormattingAndUndoSaveRealMarkdown() async throws {
        _ = NSApplication.shared
        let actions = FormattingActions()
        var saved = ""
        var error: String?
        let view = NativePageView(html: "Hello world", resources: nil, size: 17, family: .system,
            dracula: false, actions: actions, onChange: { saved = $0 }, onFiles: { _ in }, onError: { error = $0 })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(actions.editor)
        #expect(editor.isEditable)
        #expect(editor.frame.width >= 700, "Editor: \(editor.frame); host: \(host.frame)")
        #expect(editor.string == "Hello world")
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        actions.toggle(.boldFontMask)
        #expect(saved.contains("**Hello** world"))
        try await Task.sleep(for: .milliseconds(20))
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.string == "Hello world")
        let reverted = NativePageCodec.encode(try #require(editor.textStorage), markdown: true)
        #expect(!reverted.contains("**Hello**"))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" again", replacementRange: editor.selectedRange())
        #expect(saved.contains("world again"))
        #expect(error == nil)
    }

    @Test func paragraphStylesPreserveTextAndDoNotTurnAllMonospaceIntoCode() throws {
        let decoded = try NativePageCodec.decode("<h1>Title</h1><p>Body <strong>bold</strong></p>",
                                                  resources: nil, family: .monospace)
        let markdown = NativePageCodec.encode(decoded, markdown: true)
        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("**bold**"))
        #expect(!markdown.contains("`"))
        let restored = try FormattedPage(markdown: markdown)
        #expect(restored.blocks.count == 2)
        #expect(restored.blocks[1].runs.map(\.text).joined() == "Body bold")
    }

    @Test func imageReferencesSurviveNativeRoundTripWithoutEmbeddingOrShrinkingBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.jpg")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: file)
        let resources = ImportedResources(source: folder.appendingPathComponent("note.md"), root: folder)
        let decoded = try NativePageCodec.decode("<p><img src=\"photo.jpg\" alt=\"Original\"></p>", resources: resources)
        let markdown = NativePageCodec.encode(decoded, markdown: true)
        #expect(markdown == "![Original](photo.jpg)")
        let original = try Data(contentsOf: file)
        #expect(original == bytes)
        #expect(!markdown.contains("base64"))
    }
}
