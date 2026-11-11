import AppKit
import NotesCore
import SwiftSoup
import Testing
@testable import Folio

struct NoteExportTests {
    @Test func formatsProduceRealConvertedContentWithoutChangingTheNote() throws {
        let note = Note(notebookID: UUID(), title: "Export <sample>",
                        body: "# Heading\n\nA **bold** line & a [link](https://example.com).\n\n- [x] Done")
        #expect(try NoteExportFormat.markdown.contents(of: note) == note.body)
        let html = try NoteExportFormat.html.contents(of: note)
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("Export &lt;sample&gt;"))
        #expect(!html.contains("folio-resource:"))
        let text = try NoteExportFormat.plainText.contents(of: note)
        #expect(text.contains("Heading\n"))
        #expect(text.contains("A bold line & a link."))
        #expect(text.contains("[x] Done"))
        #expect(!text.contains("**") && !text.contains("<strong>"))
        #expect(note.body.contains("**bold**"))
    }

    @Test func htmlNotesConvertOrExplainUnsupportedMarkdownRatherThanChangingTheExtension() throws {
        let note = Note(notebookID: UUID(), title: "HTML",
                        body: "<h2>Heading</h2><p>A <strong>bold</strong> line.</p><script>doNotExport()</script>",
                        format: .html)
        let markdown = try NoteExportFormat.markdown.contents(of: note)
        #expect(markdown.contains("## Heading") && markdown.contains("**bold**"))
        let text = try NoteExportFormat.plainText.contents(of: note)
        #expect(text.contains("Heading\n") && text.contains("A bold line."))
        #expect(!text.contains("doNotExport"))
        let html = try NoteExportFormat.html.contents(of: note)
        #expect(!html.contains("doNotExport"))
        var complex = note
        complex.body = "<h3>Preserve this heading</h3>"
        #expect(throws: (any Error).self) { try NoteExportFormat.markdown.contents(of: complex) }
        #expect(try NoteExportFormat.html.contents(of: complex).contains("<h3>Preserve this heading</h3>"))
    }

    @Test func exportedHTMLResolvesContainedLocalImagesWithoutProprietaryPreviewURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: image)
        let note = Note(notebookID: UUID(), title: "Image", body: "![An image](image.png)",
                        importedSourceURL: root.appendingPathComponent("note.md"), importedRootURL: root)
        let exported = try NoteExportFormat.html.contents(of: note)
        let document = try SwiftSoup.parse(exported)
        let element = try #require(document.select("img").first())
        #expect(try element.attr("src") == image.standardizedFileURL.resolvingSymlinksInPath().absoluteString)
        #expect(!exported.contains("folio-resource:"))
    }
}

@Suite(.serialized)
@MainActor
struct NoteExportPanelTests {
    @Test(arguments: [350.0, 520.0])
    func formatRowHasNativeInsetsAndFitsWithoutClipping(width: Double) throws {
        let export = NoteExportPanel(note: Note(notebookID: UUID(), title: "Synthetic export"))
        let accessory = try #require(export.panel.accessoryView)
        accessory.setFrameSize(NSSize(width: width, height: 52))
        accessory.layoutSubtreeIfNeeded()
        let label = try #require(accessory.subviews.compactMap { $0 as? NSTextField }.first)
        let labelRect = accessory.convert(label.alignmentRect(forFrame: label.frame), from: label.superview)
        let pickerRect = export.formatPicker.convert(export.formatPicker.bounds, to: accessory)
        #expect(labelRect.minX >= 24)
        #expect(pickerRect.minX >= labelRect.maxX + 8)
        #expect(pickerRect.maxX <= width - 24)
        #expect(pickerRect.width >= 170 && pickerRect.height >= 22)
        #expect(labelRect.minY >= 8 && labelRect.maxY <= accessory.bounds.height - 8)
        #expect(pickerRect.minY >= 8 && pickerRect.maxY <= accessory.bounds.height - 8)
        func baseline(_ view: NSView) -> Double {
            let y = view.isFlipped ? view.firstBaselineOffsetFromTop
                : view.bounds.height - view.firstBaselineOffsetFromTop
            return view.convert(NSPoint(x: 0, y: y), to: accessory).y
        }
        #expect(abs(baseline(label) - baseline(export.formatPicker)) <= 1)
    }

    @Test func theActualSavePanelOffersFormatsAndKeepsTheTypedNameWhileChangingExtensions() throws {
        let note = Note(notebookID: UUID(), title: "Meeting")
        let export = NoteExportPanel(note: note)
        #expect(export.panel.accessoryView != nil)
        #expect(export.panel.nameFieldStringValue == "Meeting.md")
        export.panel.nameFieldStringValue = "Renamed meeting.md"
        for (index, format) in NoteExportFormat.allCases.enumerated() {
            export.formatPicker.selectItem(at: index)
            export.formatPicker.sendAction(export.formatPicker.action, to: export.formatPicker.target)
            #expect(export.format == format)
            #expect(export.panel.nameFieldStringValue == "Renamed meeting." + format.fileExtension)
            #expect(export.panel.allowedContentTypes.first?.preferredFilenameExtension == format.fileExtension)
        }
        #expect(!export.panel.isExtensionHidden)
        let html = NoteExportPanel(note: Note(notebookID: UUID(), title: "Imported", format: .html))
        #expect(html.format == .html && html.panel.nameFieldStringValue == "Imported.html")
    }
}
