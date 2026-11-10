import AppKit
import NotesCore
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct RichClipboardTests {
    @Test func richInsertionRetainsHeadingSizesAsWellAsSemantics() throws {
        let content = try RichClipboard.fromHTML("<h1>Title</h1><p>Body</p>")
        let decoded = try NativePageCodec.decode(content.page.html(), resources: nil, size: 15)
        #expect((decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 27)
        let editor = try makeEditor("Keep")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        try editor.insertRich(content)
        #expect((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 28.8)
    }

    @Test func htmlPreservesInlineStylesLinksHeadingsListsAndIgnoresActiveContent() throws {
        let content = try RichClipboard.fromHTML("""
        <style>body{background:url(https://example.com/never)}</style><script>bad()</script>
        <h1>Title</h1><div><span style="font-weight:700;font-style:italic;text-decoration:underline line-through">Styled</span>
        <a href="https://example.com">link</a><a href="javascript:bad()">unsafe</a></div>
        <ul><li>Bullet</li></ul><pre>code</pre>
        """)
        #expect(content.page.blocks.map(\.style) == [.heading1, .paragraph, .bullet, .code])
        let runs = content.page.blocks[1].runs
        let styled = try #require(runs.first { $0.text == "Styled" })
        #expect(styled.bold && styled.italic && styled.underline && styled.struck)
        #expect(runs.contains { $0.link == "https://example.com" })
        #expect(!content.page.html().contains("javascript:"))
        #expect(!content.page.html().contains("bad()"))
        #expect(content.images.isEmpty)
        let nested = try RichClipboard.fromHTML("<p style='font-weight:bold'><span style='font-style:italic'>Nested</span></p>")
        let run = try #require(nested.page.blocks.first?.runs.first)
        #expect(run.bold && run.italic && run.text == "Nested")
        let fragment = try RichClipboard.fromHTML("<span style='font-weight:bold;font-style:italic'>Selected word</span>")
        let word = try #require(fragment.page.blocks.first?.runs.first)
        #expect(word.bold && word.italic && word.text == "Selected word")
    }

    @Test func consecutiveCopiesOfTheSameEmbeddedImageAreNotCollapsed() throws {
        let bytes = try image()
        let wrapper = FileWrapper(regularFileWithContents: bytes)
        wrapper.preferredFilename = "Same.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let text = NSAttributedString(string: "\u{fffc}\u{fffc}", attributes: [.attachment: attachment])
        let content = try RichClipboard.fromAttributed(text)
        #expect(content.images.count == 2)
        #expect(content.page.blocks.flatMap(\.runs).compactMap(\.image).count == 2)
        #expect(content.images.allSatisfy { $0.data == bytes })
    }

    @Test func realRTFRoundTripPreservesStylesAndDoesNotCarryThemeColors() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = try makeEditor("**Bold** *italic* <u>under</u> ~~strike~~ `code` [Link](https://example.com)")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        #expect(editor.copy(to: board))
        let rtf = try #require(board.data(forType: .rtf))
        board.clearContents()
        board.setData(rtf, forType: .rtf)
        let read = try RichClipboard.read(board)
        let content = try #require(read)
        let runs = content.page.blocks.flatMap(\.runs)
        #expect(runs.contains { $0.bold && $0.text == "Bold" })
        #expect(runs.contains { $0.italic && $0.text == "italic" })
        #expect(runs.contains { $0.underline && $0.text == "under" })
        #expect(runs.contains { $0.struck && $0.text == "strike" })
        #expect(runs.contains { $0.code && $0.text == "code" })
        #expect(runs.contains { $0.link == "https://example.com" })
        let native = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let foreground = try #require(native.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(foreground.usingColorSpace(.deviceRGB)?.redComponent == 0)
    }

    @Test func embeddedImagesSurviveOriginalDeletionAndImportWithUndoRedo() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Original.png")
        let bytes = try image()
        try bytes.write(to: original)
        let source = try makeEditor("**Before** ![Picture](Original.png) *After*")
        let resources = ImportedResources(source: folder.appendingPathComponent("Note.md"), root: folder)
        source.resources = resources
        let page = try FormattedPage(markdown: "**Before** ![Picture](Original.png) *After*")
        source.textStorage?.setAttributedString(try NativePageCodec.decode(page.html(), resources: resources))
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(source.copy(to: board))
        let rtfd = try #require(board.data(forType: .rtfd))
        let html = try #require(board.string(forType: .html))
        #expect(html.contains("data:image/png;base64,"))
        #expect(board.data(forType: .rtf) == nil)
        try FileManager.default.removeItem(at: original)
        board.clearContents()
        board.setData(rtfd, forType: .rtfd)
        let read = try RichClipboard.read(board)
        let decoded = try #require(read)
        #expect(decoded.images.count == 1)
        #expect(decoded.images.first?.data == bytes)
        #expect(decoded.page.blocks.flatMap(\.runs).contains { $0.bold && $0.text == "Before" })
        let destination = try makeEditor("Keep")
        destination.setSelectedRange(NSRange(location: 0, length: 4))
        destination.onError = { Issue.record("\($0)") }
        destination.onImportFiles = { files in
            try Attachments.importing(files: files, for: Note(notebookID: UUID(), format: .formatted),
                                      directory: folder.appendingPathComponent("Imported"))
        }
        destination.paste(from: board)
        let saved = try FormattedPage(markdown: NativePageCodec.encode(destination.attributedString(), markdown: true))
        let reference = try #require(saved.blocks.flatMap(\.runs).compactMap(\.image).first)
        let local = try #require(destination.resources?.localURL(for: reference))
        let copied = try Data(contentsOf: local)
        #expect(copied == bytes)
        let undo = try #require(destination.undoManager)
        try await Task.sleep(for: .milliseconds(20))
        undo.undo()
        #expect(destination.string == "Keep")
        undo.redo()
        #expect(destination.string.contains("\u{fffc}"))
        #expect(FileManager.default.fileExists(atPath: local.path))
        let htmlContent = try RichClipboard.fromHTML(html)
        #expect(htmlContent.images.first?.data == bytes)
    }

    @Test func nativeRTFDBulletsRoundTripAsListsInsteadOfLiteralMarkers() throws {
        let source = try makeEditor("- First **bold**\n- Second")
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(source.copy(to: board))
        let rtfd = try #require(board.data(forType: .rtfd))
        board.clearContents()
        board.setData(rtfd, forType: .rtfd)
        let read = try RichClipboard.read(board)
        let page = try #require(read).page
        #expect(page.blocks.map(\.style) == [.bullet, .bullet])
        #expect(page.blocks[0].runs.map(\.text).joined() == "First bold")
        #expect(page.blocks[1].runs.map(\.text).joined() == "Second")
    }

    @Test func rejectionNeverReplacesSelectionOrSilentlyFallsBackToPlainText() throws {
        let editor = try makeEditor("Keep")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var errors: [String] = []
        editor.onError = { errors.append($0) }
        for html in ["<table><tr><td>Lost</td></tr></table>",
                     "<p><img src='https://example.com/image.png'></p>",
                     "<p><img src='file:///not-authorized.png'></p>",
                     "<ol><li>Numbered</li></ol>"] {
            board.clearContents()
            board.setString(html, forType: .html)
            board.setString("Silent fallback", forType: .string)
            editor.paste(from: board)
            #expect(editor.string == "Keep")
            #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
        }
        #expect(errors.count == 4)
        let png = try image()
        board.clearContents()
        board.setString("<p><b>Text</b><img src='data:image/png;base64,\(png.base64EncodedString())'></p>", forType: .html)
        editor.onImportFiles = { _ in throw NoteWorkflowError("Disk unavailable") }
        editor.paste(from: board)
        #expect(editor.string == "Keep")
        #expect(errors.last?.contains("Disk unavailable") == true)
        editor.isEditable = false
        editor.paste(from: board)
        #expect(errors.count == 5)
    }

    @Test func malformedRichDataAndUnembeddableCopyLeaveExistingClipboardIntact() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data([0, 1, 2]), forType: .rtfd)
        #expect(throws: (any Error).self) { try RichClipboard.read(board) }
        board.clearContents()
        board.setString("Previous clipboard", forType: .string)
        let source = try makeEditor("![Missing](missing.png)")
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        var error: String?
        source.onError = { error = $0 }
        #expect(!source.copy(to: board))
        #expect(board.string(forType: .string) == "Previous clipboard")
        #expect(error?.contains("missing") == true)
    }

    @Test func privateHTMLPreferredAndPortableCodeQuoteEmptyParagraphsRoundTrip() throws {
        let source = try makeEditor("# Title\n\n> Quote\n\n```\nlet x = 1\n```\n\nBody")
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(source.copy(to: board))
        let read = try RichClipboard.read(board)
        let page = try #require(read).page
        #expect(page.blocks.map(\.style) == [.heading1, .quote, .code, .paragraph])
        #expect(page.markdown() == NativePageCodec.encode(source.attributedString(), markdown: true))
    }

    @Test func cutIsUndoableAndExplicitPlainPasteIsLiteral() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = try makeEditor("**Bold** Keep")
        source.setSelectedRange(NSRange(location: 0, length: 4))
        source.cut(to: board)
        #expect(source.string == " Keep")
        #expect(board.string(forType: .string) == "Bold")
        try await Task.sleep(for: .milliseconds(20))
        try #require(source.undoManager).undo()
        #expect(NativePageCodec.encode(source.attributedString(), markdown: true) == "**Bold** Keep")
        board.clearContents()
        board.setString("**Literal**", forType: .string)
        board.setString("<table><tr><td>Ignored only by explicit text paste</td></tr></table>", forType: .html)
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        source.pastePlain(from: board)
        #expect(source.string == "**Literal**")
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        source.isEditable = false
        source.cut(to: board)
        #expect(source.string == "**Literal**")
    }

    private func makeEditor(_ source: String) throws -> PageTextView {
        _ = NSApplication.shared
        let editor = PageTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        editor.isRichText = true
        editor.allowsUndo = true
        let page = try FormattedPage(markdown: source)
        editor.textStorage?.setAttributedString(try NativePageCodec.decode(page.html(), resources: nil, color: NSColor(FolioPalette.foreground)))
        editor.typingAttributes = NativePageCodec.attributes(style: .paragraph, size: 16, family: .system, color: .textColor)
        return editor
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func image() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
