import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct NativeEditorTests {
    @Test func shortcutUndoRedoRestoresTypingStyleAndMarkedTextIsNeverPaired() async throws {
        _ = NSApplication.shared
        let editor = PageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.allowsUndo = true
        editor.isRichText = true
        editor.markdownShortcuts = true
        editor.typingAttributes = NativePageCodec.attributes(style: .paragraph, size: 16, family: .system, color: .textColor)
        editor.insertText("#", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(20))
        editor.insertText(" ", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(20))
        #expect(editor.string.isEmpty)
        editor.undoManager?.undo()
        #expect(editor.string == "#")
        #expect(editor.typingAttributes[.folioBlock] as? String == FormattedBlock.Style.paragraph.rawValue)
        editor.undoManager?.redo()
        editor.insertText("Heading", replacementRange: editor.selectedRange())
        #expect(NativePageCodec.encode(try #require(editor.textStorage), markdown: true) == "# Heading")

        let source = SourceTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        source.pairDelimiters = true
        source.setMarkedText("(", selectedRange: NSRange(location: 1, length: 0), replacementRange: source.selectedRange())
        #expect(source.hasMarkedText())
        source.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(source.string == "(")
        #expect(!source.hasMarkedText())
    }

    @Test func delimiterPairingIsOptInUndoableAndPreservesUnicodeSelections() async throws {
        _ = NSApplication.shared
        let editor = SourceTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.allowsUndo = true
        editor.isRichText = false
        editor.insertText("(", replacementRange: editor.selectedRange())
        #expect(editor.string == "(")
        editor.string = ""
        editor.undoManager?.removeAllActions()
        editor.pairDelimiters = true
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("(", replacementRange: editor.selectedRange())
        #expect(editor.string == "()")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        editor.undoManager?.undo()
        #expect(editor.string.isEmpty)
        editor.undoManager?.redo()
        #expect(editor.string == "()")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.string.isEmpty)
        editor.string = "a😀b"
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        editor.insertText("[", replacementRange: editor.selectedRange())
        #expect(editor.string == "a[😀]b")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 2))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText("]", replacementRange: editor.selectedRange())
        #expect(editor.string == "a[😀]b")
        #expect(editor.selectedRange().location == 5)
        editor.string = "can"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("'", replacementRange: editor.selectedRange())
        #expect(editor.string == "can'")
        editor.isEditable = false
        editor.insertText("(", replacementRange: editor.selectedRange())
        #expect(editor.string == "can'")
    }

    @Test func markdownShortcutsAreOptInPersistFormattingAndLeaveCodeAndPasteLiteral() throws {
        _ = NSApplication.shared
        let editor = PageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        editor.isRichText = true
        editor.allowsUndo = true
        func reset(_ style: FormattedBlock.Style = .paragraph) {
            editor.string = ""
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.typingAttributes = NativePageCodec.attributes(style: style, size: 16, family: .system, color: .textColor)
            editor.undoManager?.removeAllActions()
        }
        reset()
        editor.insertText("#", replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        #expect(editor.string == "# ")
        editor.markdownShortcuts = true
        reset()
        for value in ["#", " ", "Heading"] { editor.insertText(value, replacementRange: editor.selectedRange()) }
        #expect(NativePageCodec.encode(try #require(editor.textStorage), markdown: true) == "# Heading")
        reset()
        for value in ["-", " ", "[ ]", " ", "Task"] { editor.insertText(value, replacementRange: editor.selectedRange()) }
        #expect(NativePageCodec.encode(try #require(editor.textStorage), markdown: true) == "- [ ] Task")
        reset(.code)
        for value in ["#", " ", "literal"] { editor.insertText(value, replacementRange: editor.selectedRange()) }
        #expect(editor.string == "# literal")
        #expect(editor.typingAttributes[.folioBlock] as? String == FormattedBlock.Style.code.rawValue)
        reset()
        let board = NSPasteboard(name: .init("DeltosEditorPreferences-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("# literal\n- literal", forType: .string)
        editor.pastePlain(from: board)
        #expect(editor.string == "# literal\n- literal")
        #expect(editor.typingAttributes[.folioBlock] as? String == FormattedBlock.Style.paragraph.rawValue)
    }

    @Test func nativeTypingFormattingAndUndoSaveRealMarkdown() async throws {
        _ = NSApplication.shared
        let actions = FormattingActions()
        var saved = ""
        var error: String?
        let view = NativePageView(html: "Hello world", resources: nil, size: 17, family: .system,
            dracula: false, actions: actions, onChange: { saved = $0 }, onError: { error = $0 })
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

    @Test func composeImagesFillThePageAndOpenInTheDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let file = folder.appendingPathComponent("photo.jpg")
        try bytes.write(to: file)
        let resources = ImportedResources(source: folder.appendingPathComponent("note.md"), root: folder)
        let actions = FormattingActions()
        var opened: URL?
        var error: String?
        let view = NativePageView(html: "![Photo](photo.jpg)", resources: resources, size: 17, family: .system,
            dracula: false, actions: actions, onChange: { _ in },
            onError: { error = $0 }, onImage: { opened = $0 })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(actions.editor)
        let attachment = try #require(editor.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width >= 900)
        #expect(abs(attachment.bounds.width / attachment.bounds.height - 1.6) < 0.01)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        #expect(editor.openImage(at: NSPoint(x: rect.midX + editor.textContainerOrigin.x,
                                            y: rect.midY + editor.textContainerOrigin.y)))
        #expect(opened == file)
        #expect(error == nil)
        let preserved = try Data(contentsOf: file)
        #expect(preserved == bytes)
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
