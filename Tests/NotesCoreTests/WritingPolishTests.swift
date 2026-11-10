import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct WritingPolishTests {
    @Test func mixedFormattingUsesTheWholeSelectionAndReflectsCaretChanges() throws {
        let (editor, actions) = try editor("**Bold** plain")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        actions.refresh()
        #expect(!actions.bold)
        actions.toggle(.boldFontMask)
        #expect(actions.bold)
        #expect(markdown(editor) == "**Bold plain**")
        actions.toggle(.boldFontMask)
        #expect(!actions.bold)
        #expect(markdown(editor) == "Bold plain")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        actions.toggle(.italicFontMask)
        #expect(actions.italic)
        editor.setSelectedRange(NSRange(location: 6, length: 2))
        actions.refresh()
        #expect(!actions.italic)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 2))
    }

    @Test func inlineFormattingAndLinkRemovalArePortableAndUndoable() async throws {
        let (editor, actions) = try editor("Some words")
        editor.setSelectedRange(NSRange(location: 5, length: 5))
        actions.toggleInline(.underlineStyle)
        actions.toggleInline(.strikethroughStyle)
        actions.toggleInline(.folioCode)
        actions.addLink("https://example.com")
        #expect(actions.underline && actions.struck && actions.code && actions.linked)
        let restored = try FormattedPage(markdown: markdown(editor))
        let run = try #require(restored.blocks.first?.runs.last)
        #expect(run.text == "words")
        #expect(run.underline && run.struck && run.code)
        #expect(run.link == "https://example.com")
        try await Task.sleep(for: .milliseconds(20))
        actions.removeLink()
        #expect(!markdown(editor).contains("https://"))
        try #require(editor.undoManager).undo()
        #expect(markdown(editor).contains("https://example.com"))
        actions.toggleInline(.folioCode)
        #expect(!actions.code)
        #expect(!markdown(editor).contains("`"))
    }

    @Test func paragraphChangesPreserveSelectionLinksAndExplicitBoldWithoutBlankLines() async throws {
        let source = "First **bold**\n\nSecond [link](https://example.com)\n\nLast"
        let (editor, actions) = try editor(source)
        let original = editor.string
        let selected = (original as NSString).range(of: "bold\nSecond link")
        editor.setSelectedRange(selected)
        actions.setStyle(.bullet)
        #expect(editor.string == "\u{2022} First bold\n\u{2022} Second link\nLast")
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "bold\n\u{2022} Second link")
        let page = try FormattedPage(markdown: markdown(editor))
        #expect(page.blocks.count == 3)
        #expect(page.blocks.map(\.style) == [.bullet, .bullet, .paragraph])
        #expect(page.blocks[0].runs.contains { $0.bold && $0.text == "bold" })
        #expect(page.blocks[1].runs.contains { $0.link == "https://example.com" })
        try await Task.sleep(for: .milliseconds(20))
        actions.setStyle(.paragraph)
        #expect(editor.string == original)
        #expect(editor.selectedRange() == selected)
        try #require(editor.undoManager).undo()
        #expect(editor.string.hasPrefix("\u{2022} First"))
        try #require(editor.undoManager).undo()
        #expect(editor.string == original)
        #expect(editor.selectedRange() == selected)
    }

    @Test func headingsDoNotCreateExplicitBoldAndAnEmptyBulletStartsAndEndsNaturally() throws {
        let (editor, actions) = try editor("# Heading\n\nBody")
        #expect(!markdown(editor).contains("**Heading**"))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        actions.setStyle(.paragraph)
        #expect(markdown(editor) == "Heading\n\nBody")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertNewline(nil)
        actions.setStyle(.bullet)
        #expect(editor.string.hasSuffix("\n\u{2022} "))
        editor.insertNewline(nil)
        #expect(editor.string.hasSuffix("\n"))
        #expect(editor.typingAttributes[.folioBlock] as? String == FormattedBlock.Style.paragraph.rawValue)
    }

    @Test func caretFormattingAppliesToNewWordsAndInvalidLinksLeaveTheSelectionIntact() throws {
        let (editor, actions) = try editor("Keep")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        actions.toggle(.boldFontMask)
        actions.toggleInline(.underlineStyle)
        #expect(markdown(editor) == "Keep")
        editor.insertText(" new", replacementRange: editor.selectedRange())
        #expect(markdown(editor) == "Keep <u>**new**</u>")
        editor.setSelectedRange(NSRange(location: 5, length: 3))
        var error: String?
        editor.onError = { error = $0 }
        for invalid in ["https://", "mailto:", "mailto:?subject=Hello", "mailto:#fragment",
                        "relative/page", "javascript:alert(1)", "https://example.com/a b"] {
            #expect(!actions.addLink(invalid))
            #expect(editor.selectedRange() == NSRange(location: 5, length: 3))
            #expect(!markdown(editor).contains("]("))
            #expect(error != nil)
        }
        #expect(actions.addLink("mailto:notes@example.com"))
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        actions.removeLink()
        #expect(!markdown(editor).contains("mailto:"))
        #expect(editor.string == "Keep new")
    }

    @Test func paragraphStylesPreserveUTF16SelectionAndImageReferences() throws {
        let (editor, actions) = try editor("Hello 🌍\n\n![Photo](photo.png)\n\nEnd")
        let source = editor.string
        let selection = (source as NSString).range(of: "🌍")
        editor.setSelectedRange(selection)
        actions.setStyle(.bullet)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "🌍")
        actions.setStyle(.heading2)
        #expect(editor.selectedRange() == selection)
        #expect(markdown(editor).contains("![Photo](photo.png)"))
        let restored = try FormattedPage(markdown: markdown(editor))
        #expect(restored.blocks.count == 3)
        #expect(!markdown(editor).contains("**Hello"))
    }

    @Test func clipboardPNGIsCopiedAtTheCaretAndUndoKeepsTheOriginalFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = try imageBytes(.png)
        board.setData(bytes, forType: .png)
        board.setString("Ignored image caption", forType: .string)
        let (editor, _) = try editor("BeforeAfter")
        editor.onImportFiles = { files in
            try Attachments.importing(files: files, for: Note(notebookID: UUID(), format: .formatted),
                                     directory: folder)
        }
        var error: String?
        editor.onError = { error = $0 }
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.paste(from: board)
        #expect(editor.string == "Before\n\u{fffc}\nAfter")
        let storage = try #require(editor.textStorage)
        let reference = try #require(storage.attribute(.folioImage, at: 7, effectiveRange: nil) as? String)
        let local = try #require(editor.resources?.localURL(for: reference))
        let copied = try Data(contentsOf: local)
        #expect(copied == bytes)
        #expect(markdown(editor).contains("Pasted%20image.png"))
        #expect(!markdown(editor).contains("base64"))
        let undo = try #require(editor.undoManager)
        undo.undo()
        #expect(editor.string == "BeforeAfter")
        undo.redo()
        #expect(editor.string == "Before\n\u{fffc}\nAfter")
        #expect(FileManager.default.fileExists(atPath: local.path))
        #expect(error == nil)
    }

    @Test func tiffPasteConvertsToPortablePNGAndBadImagesNeverReplaceSelectedText() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try imageBytes(.tiff), forType: .tiff)
        let (editor, _) = try editor("Keep")
        editor.onImportFiles = { files in
            #expect(files[0].pathExtension == "png")
            return try Attachments.importing(files: files, for: Note(notebookID: UUID(), format: .formatted),
                                             directory: folder)
        }
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.paste(from: board)
        #expect(editor.string == "\u{fffc}")
        let reference = try #require(editor.textStorage?.attribute(.folioImage, at: 0, effectiveRange: nil) as? String)
        let file = try #require(editor.resources?.localURL(for: reference))
        let png = try Data(contentsOf: file)
        #expect(NSBitmapImageRep(data: png) != nil)
        let before = markdown(editor)
        board.clearContents()
        board.setData(Data([0, 1, 2]), forType: .png)
        board.setString("Do not silently use this instead", forType: .string)
        var error: String?
        editor.onError = { error = $0 }
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        editor.paste(from: board)
        #expect(markdown(editor) == before)
        #expect(error?.contains("clipboard image") == true)
    }

    @Test func attachmentFailureAndReadOnlyPastePreserveTheBufferAndPlainTextStaysLiteral() throws {
        let (editor, _) = try editor("Keep")
        var error: String?
        editor.onError = { error = $0 }
        editor.onImportFiles = { _ in throw NoteWorkflowError("Disk unavailable") }
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(!editor.insertFiles([URL(fileURLWithPath: "/unused.png")]))
        #expect(editor.string == "Keep")
        #expect(error?.contains("Disk unavailable") == true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("**literal**", forType: .string)
        editor.isEditable = false
        editor.paste(from: board)
        #expect(editor.string == "Keep")
        editor.isEditable = true
        editor.paste(from: board)
        #expect(editor.string == "**literal**")
        #expect(markdown(editor).contains("\\*\\*literal\\*\\*"))
    }

    @Test func resourceUpdatesAfterInsertionDoNotResetNativeSelectionOrUndo() async throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("example.png")
        try imageBytes(.png).write(to: input)
        let actions = FormattingActions()
        var body = "BeforeAfter"
        var resources: ImportedResources?
        @MainActor func view() -> NativePageView {
            NativePageView(html: body, resources: resources, size: 17, family: .system, dracula: false,
                actions: actions, onChange: { body = $0 },
                onError: { Issue.record("\($0)") }, currentSource: { body },
                onImportFiles: { files in
                    let imported = try Attachments.importing(files: files,
                        for: Note(notebookID: UUID(), format: .formatted), directory: folder.appendingPathComponent("Assets"))
                    resources = imported.resources
                    return imported
                })
        }
        let host = NSHostingView(rootView: view())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120))
        let editor = try #require(actions.editor)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(editor.insertFiles([input]))
        let selection = editor.selectedRange()
        host.rootView = view()
        try await Task.sleep(for: .milliseconds(120))
        #expect(actions.editor === editor)
        #expect(editor.selectedRange() == selection)
        #expect(editor.isEditable)
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(body == "BeforeAfter")
        undo.redo()
        #expect(body.contains("example.png"))
    }

    @Test func hostedToolbarAndFontChangesFollowTheCurrentParagraphWithoutCollapsingSelection() async throws {
        _ = NSApplication.shared
        let actions = FormattingActions()
        var size = 17.0
        @MainActor func view() -> NativePageView {
            NativePageView(html: "# Heading\n\nBody", resources: nil, size: size, family: .system, dracula: false,
                actions: actions, onChange: { _ in Issue.record("Changing display settings must not rewrite a note.") },
                onError: { Issue.record("\($0)") })
        }
        let host = NSHostingView(rootView: view())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120))
        let editor = try #require(actions.editor)
        #expect(actions.style == .heading1)
        #expect(!actions.bold)
        let selection = (editor.string as NSString).range(of: "Body")
        editor.setSelectedRange(selection)
        #expect(actions.style == .paragraph)
        size = 20
        host.rootView = view()
        try await Task.sleep(for: .milliseconds(120))
        #expect(editor.selectedRange() == selection)
        #expect(actions.style == .paragraph)
        #expect(markdown(editor) == "# Heading\n\nBody")
    }

    @Test func composeResourceOwnershipIsPersistedBeforeInsertionAndFailedSavesRollBack() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosWriting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Writing")
        let note = Note(notebookID: notebook.id, body: "Existing words", format: .formatted)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        let input = root.appendingPathComponent("example.png")
        try imageBytes(.png).write(to: input)
        let imported = try store.importComposeAttachments([input], to: note.id)
        let persisted = try #require(storage.load()?.notes.first)
        #expect(persisted.body == "Existing words")
        #expect(persisted.importedRootURL == imported.resources.root)
        #expect(persisted.importedSourceURL == imported.resources.source)
        let before = store.library
        let contents = try FileManager.default.contentsOfDirectory(at: imported.resources.root, includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.importComposeAttachments([input], to: note.id) }
        #expect(store.library == before)
        let after = try FileManager.default.contentsOfDirectory(at: imported.resources.root, includingPropertiesForKeys: nil)
        #expect(Set(contents) == Set(after))
    }

    @Test func composeImagePasteAndUndoPersistThroughTheRealNoteWindow() async throws {
        _ = NSApplication.shared
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosWritingWindow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Writing")
        let note = Note(notebookID: notebook.id, title: "Synthetic paste fixture", body: "BeforeAfter", format: .formatted)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.openNote(note.id)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        @MainActor func findEditor(in view: NSView) -> PageTextView? {
            if let editor = view as? PageTextView { return editor }
            return view.subviews.compactMap { findEditor(in: $0) }.first
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if findEditor(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(findEditor(in: host))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = try imageBytes(.png)
        board.setData(bytes, forType: .png)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.paste(from: board)
        try await Task.sleep(for: .milliseconds(120))
        #expect(findEditor(in: host) === editor)
        #expect(editor.string == "Before\n\u{fffc}\nAfter")
        let saved = try #require(storage.load()?.notes.first)
        let page = try FormattedPage(markdown: saved.body)
        #expect(page.blocks.count == 3)
        #expect(page.blocks[0].runs.map(\.text).joined() == "Before")
        #expect(page.blocks[2].runs.map(\.text).joined() == "After")
        let reference = try #require(page.blocks[1].runs.first?.image)
        let image = try #require(editor.resources?.localURL(for: reference))
        let copied = try Data(contentsOf: image)
        #expect(copied == bytes)
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        let undone = try #require(storage.load()?.notes.first)
        #expect(undone.body == "BeforeAfter")
        undo.redo()
        try await Task.sleep(for: .milliseconds(50))
        let redone = try #require(storage.load()?.notes.first)
        #expect(redone.body == saved.body)
        #expect(store.errorMessage == nil)
        #expect(!store.hasUnsavedChanges)
    }

    private func editor(_ markdown: String) throws -> (PageTextView, FormattingActions) {
        _ = NSApplication.shared
        let editor = PageTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        editor.isRichText = true
        editor.allowsUndo = true
        let page = try FormattedPage(markdown: markdown)
        editor.textStorage?.setAttributedString(try NativePageCodec.decode(page.html(), resources: nil))
        editor.typingAttributes = NativePageCodec.attributes(style: .paragraph, size: 16, family: .system, color: .textColor)
        let actions = FormattingActions()
        actions.editor = editor
        return (editor, actions)
    }

    private func markdown(_ editor: PageTextView) -> String {
        NativePageCodec.encode(editor.attributedString(), markdown: true)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func imageBytes(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: type, properties: [:]))
    }
}
