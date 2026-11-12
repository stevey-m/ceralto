import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct WritingPolishTests {
    @Test func relativeTextSizesPreserveMixedRunsAndUndoWithoutChangingOtherText() async throws {
        let (editor, actions) = try editor("Small **large** outside")
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        actions.setFontSize(12)
        editor.setSelectedRange(NSRange(location: 6, length: 5))
        actions.setFontSize(24)
        let original = markdown(editor)
        let selection = NSRange(location: 0, length: 11)
        editor.setSelectedRange(selection)
        actions.refresh()
        #expect(actions.selectedFontSize == nil)
        try await Task.sleep(for: .milliseconds(20))
        actions.adjustFontSize(by: 1)
        let page = try FormattedPage(markdown: markdown(editor))
        let runs = page.blocks[0].runs
        #expect(runs.contains { $0.text == "Small" && $0.fontSize == 13 })
        #expect(runs.contains { $0.text == "large" && $0.fontSize == 25 && $0.bold })
        #expect(runs.contains { $0.text.contains("outside") && $0.fontSize == nil })
        #expect(editor.selectedRange() == selection)
        try #require(editor.undoManager).undo()
        #expect(markdown(editor) == original)
        try #require(editor.undoManager).redo()
        #expect(try FormattedPage(markdown: markdown(editor)).blocks[0].runs.contains { $0.fontSize == 25 })
    }

    @Test func relativeTextSizesAtCaretAffectOnlyNewTypingAndRejectOutOfRangeSelection() throws {
        let (editor, actions) = try editor("Keep")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        actions.setFontSize(19.5)
        actions.adjustFontSize(by: -1)
        #expect(actions.selectedFontSize == 18.5)
        #expect(markdown(editor) == "Keep")
        editor.insertText(" new", replacementRange: editor.selectedRange())
        #expect(try FormattedPage(markdown: markdown(editor)).blocks[0].runs.contains { $0.fontSize == 18.5 })
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        actions.setFontSize(512)
        let before = markdown(editor)
        var error: String?
        editor.onError = { error = $0 }
        actions.adjustFontSize(by: 1)
        #expect(error != nil)
        #expect(markdown(editor) == before)
    }

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

    @Test func nativeOrderedChecklistAndTableActionsRoundTripAndUndo() async throws {
        let (editor, actions) = try editor("First\n\nSecond")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        actions.setStyle(.ordered)
        #expect(markdown(editor).contains("1. First\n2. Second"))
        actions.indentList(by: 1)
        let nested = try FormattedPage(markdown: markdown(editor))
        #expect(nested.blocks.map(\.listDepth) == [0, 1])
        try await Task.sleep(for: .milliseconds(20))
        try #require(editor.undoManager).undo()
        #expect(try FormattedPage(markdown: markdown(editor)).blocks.map(\.listDepth) == [0, 0])

        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        actions.setStyle(.checklist)
        #expect(try FormattedPage(markdown: markdown(editor)).blocks.allSatisfy { $0.style == .checklist && !$0.checked })
        try await Task.sleep(for: .milliseconds(20))
        editor.toggleChecklistItem(at: 0)
        #expect(try FormattedPage(markdown: markdown(editor)).blocks.first?.checked == true)
        try await Task.sleep(for: .milliseconds(20))
        try #require(editor.undoManager).undo()
        let unchecked = try FormattedPage(markdown: markdown(editor)).blocks
        #expect(unchecked.map(\.style) == [.checklist, .checklist])
        #expect(unchecked.first?.checked == false)

        try await Task.sleep(for: .milliseconds(20))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        actions.insertTable()
        let table = try FormattedPage(markdown: markdown(editor)).blocks.last
        #expect(table?.style == .table)
        #expect(table?.tableRows.first?.count == 2)
        try await Task.sleep(for: .milliseconds(20))
        let headerLocation = (editor.string as NSString).range(of: "Column 1").location
        editor.setSelectedRange(NSRange(location: headerLocation, length: "Column 1".utf16.count))
        editor.insertText("Name", replacementRange: editor.selectedRange())
        #expect(try FormattedPage(markdown: markdown(editor)).blocks.last?.tableRows.first?.first?.runs.map(\.text).joined() == "Name")
        try await Task.sleep(for: .milliseconds(20))
        try #require(editor.undoManager).undo()
        #expect(try FormattedPage(markdown: markdown(editor)).blocks.last?.tableRows.first?.first?.runs.map(\.text).joined() == "Column 1")
    }

    @Test func nativeTablesLayOutAsARealGridAndPreserveRichCells() throws {
        let source = """
        Before

        | Task | Owner |
        | --- | --- |
        | **Review**<br>日本語 | [Team](https://example.com) |
        | | |

        After
        """
        let (editor, _) = try editor(source)
        let start = (editor.string as NSString).range(of: "Task").location
        let grid = try #require(NativeTableLayout.grid(in: editor.attributedString(), at: start))
        #expect(grid.cells.count == 6)
        #expect(grid.rows.count == 3 && grid.rows[0].count == 2)
        #expect(try FormattedPage(markdown: markdown(editor)).html() == FormattedPage(markdown: source).html())
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        editor.isVerticallyResizable = true
        container.widthTracksTextView = true
        for width in [340.0, 800.0] {
            editor.setFrameSize(NSSize(width: width, height: 600))
            container.containerSize = NSSize(width: width - 20, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let boxes = grid.cells.prefix(4).map { cell in
                layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: cell.body,
                    actualCharacterRange: nil), in: container)
            }
            #expect(boxes[1].minX > boxes[0].maxX + 30)
            #expect(abs(boxes[0].minY - boxes[1].minY) < 1)
            #expect(boxes[2].minY > boxes[0].maxY)
            #expect(abs(boxes[2].minY - boxes[3].minY) < 1)
            #expect(boxes.allSatisfy { $0.maxX <= width && $0.width > 0 })
        }
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = editor
        defer { window.contentView = nil }
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent("dist/Ceralto-table-grid-preview.png"))
    }

    @Test func tableRowAndColumnChangesAndDeletionUndoWithoutLosingAdjacentWriting() async throws {
        let (editor, actions) = try editor("Before\n\n| Name | State |\n| --- | --- |\n| Sample | Ready |\n\nAfter")
        for action in [TableAction.rowAbove, .rowBelow, .deleteRow, .columnBefore, .columnAfter, .deleteColumn, .deleteTable] {
            let before = markdown(editor)
            editor.setSelectedRange((editor.string as NSString).range(of: "Sample"))
            let original = try #require(actions.tableGrid)
            try await Task.sleep(for: .milliseconds(20))
            actions.performTableAction(action)
            let after = markdown(editor)
            #expect(after != before)
            let page = try FormattedPage(markdown: after)
            #expect(page.blocks.first?.runs.map(\.text).joined() == "Before")
            #expect(page.blocks.last?.runs.map(\.text).joined() == "After")
            if action != .deleteTable {
                let changed = try #require(actions.tableGrid)
                let rowDelta = action == .rowAbove || action == .rowBelow ? 1 : action == .deleteRow ? -1 : 0
                let columnDelta = action == .columnBefore || action == .columnAfter ? 1 : action == .deleteColumn ? -1 : 0
                #expect(changed.rows.count == original.rows.count + rowDelta)
                #expect(changed.rows[0].count == original.rows[0].count + columnDelta)
            } else { #expect(!page.blocks.contains { $0.style == .table }) }
            try await Task.sleep(for: .milliseconds(20))
            let undo = try #require(editor.undoManager)
            undo.undo()
            #expect(markdown(editor) == before)
            undo.redo()
            #expect(markdown(editor) == after)
            undo.undo()
        }
    }

    @Test func tableKeyboardNavigationMultilineCellsAndWritingAroundTheGrid() throws {
        let (editor, actions) = try editor("")
        actions.insertTable()
        editor.insertText("Project", replacementRange: editor.selectedRange())
        editor.insertTab(nil)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "Column 2")
        editor.insertText("Status", replacementRange: editor.selectedRange())
        editor.insertTab(nil)
        editor.insertText("Release", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        editor.insertText("日本語", replacementRange: editor.selectedRange())
        editor.insertTab(nil)
        editor.insertText("Ready\r\nNow", replacementRange: editor.selectedRange())
        editor.insertTab(nil)
        let grid = try #require(actions.tableGrid)
        #expect(grid.rows.count == 3)
        #expect(grid.current.block.startingRow == 2 && grid.current.block.startingColumn == 0)
        #expect(grid.rows[1][0].runs.map(\.text).joined() == "Release\n日本語")
        #expect(grid.rows[1][1].runs.map(\.text).joined() == "Ready\nNow")
        editor.insertBacktab(nil)
        #expect(actions.tableGrid?.current.block.startingRow == 1)
        #expect(actions.tableGrid?.current.block.startingColumn == 1)
        let reopened = try NativePageCodec.decode(FormattedPage(markdown: markdown(editor)).html(), resources: nil)
        #expect(NativeTableLayout.grid(in: reopened, at: 0)?.rows == grid.rows)
        actions.performTableAction(.writeAbove)
        editor.insertText("Before", replacementRange: editor.selectedRange())
        editor.setSelectedRange((editor.string as NSString).range(of: "Project"))
        editor.cancelOperation(nil)
        #expect(actions.tableGrid == nil)
        editor.insertText("After", replacementRange: editor.selectedRange())
        let page = try FormattedPage(markdown: markdown(editor))
        #expect(page.blocks.map(\.style) == [.paragraph, .table, .paragraph])
        #expect(page.blocks.first?.runs.map(\.text).joined() == "Before")
        #expect(page.blocks.last?.runs.map(\.text).joined() == "After")
    }

    @Test func tableCopyPasteAndCellBoundaryProtectionPreserveTheGrid() throws {
        let (editor, actions) = try editor("| Name | State |\n| --- | --- |\n| Sample | Ready |")
        editor.setSelectedRange((editor.string as NSString).range(of: "Sample"))
        let grid = try #require(actions.tableGrid)
        let before = markdown(editor)
        var error: String?
        editor.onError = { error = $0 }
        editor.setSelectedRange(NSRange(location: grid.current.body.location, length: grid.current.paragraph.length + 2))
        editor.insertText("", replacementRange: editor.selectedRange())
        #expect(markdown(editor) == before)
        #expect(error != nil)
        editor.setSelectedRange(NSRange(location: grid.current.body.location, length: 0))
        editor.deleteBackward(nil)
        #expect(markdown(editor) == before)
        editor.setSelectedRange(grid.range)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(editor.copy(to: board))
        let (destination, destinationActions) = try self.editor("LeadTail")
        destination.setSelectedRange(NSRange(location: 4, length: 0))
        destination.paste(from: board)
        let pasted = try FormattedPage(markdown: markdown(destination))
        #expect(pasted.blocks.map(\.style) == [.paragraph, .table, .paragraph])
        #expect(pasted.blocks[1].tableRows == grid.rows)
        destination.setSelectedRange((destination.string as NSString).range(of: "Sample"))
        try destination.insertRich(RichClipboard.fromHTML("<p><strong>Updated</strong><br>Next</p>"))
        let changed = try #require(destinationActions.tableGrid)
        #expect(changed.rows[1][0].runs.map(\.text).joined() == "Updated\nNext")
        #expect(changed.rows[1][0].runs.first?.bold == true)
        let saved = markdown(destination)
        #expect(throws: NoteWorkflowError.self) {
            try destination.insertRich(RichClipboard.fromHTML("<table><tr><th>Nested</th></tr></table>"))
        }
        #expect(markdown(destination) == saved)
        let persisted = try FormattedPage(markdown: saved).blocks[1].tableRows
        func tableHTML(_ rows: [[FormattedTableCell]]) -> String {
            FormattedPage(blocks: [FormattedBlock(style: .table, runs: [], tableRows: rows)]).html()
        }
        #expect(tableHTML(persisted) == tableHTML(changed.rows))
        destination.setSelectedRange((destination.string as NSString).range(of: "Updated"))
        #expect(destination.copy(to: board))
        #expect(try RichClipboard.read(board)?.page.blocks.map(\.style) == [.paragraph])
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

    @Test(arguments: [NoteFormat.formatted, .markdown, .html])
    func composeResourceOwnershipIsPersistedBeforeInsertionAndFailedSavesRollBack(format: NoteFormat) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosWriting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Writing")
        let body = format.usesHTML ? "<p>Existing words</p>" : "Existing words"
        let note = Note(notebookID: notebook.id, body: body, format: format)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        let input = root.appendingPathComponent("example.png")
        try imageBytes(.png).write(to: input)
        let imported = try store.importComposeAttachments([input], to: note.id)
        let persisted = try #require(storage.load()?.notes.first)
        #expect(persisted.body == body)
        #expect(persisted.contentFormat == format)
        let fragment = try FormattedPage(markdown: imported.fragment)
        #expect(fragment.blocks.flatMap(\.runs).contains { $0.image != nil })
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
        editor.formattingActions = actions
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
