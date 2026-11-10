import AppKit
import NotesCore
import PDFKit
import Testing
import WebKit
@testable import Folio

struct PrintDocumentTests {
    @Test func rendersAllNoteFormatsWithEscapedTitleAndLightPrintLayout() throws {
        for format in [NoteFormat.markdown, .formatted, .html] {
            let body = format == .html ? "<p>A printable paragraph</p><script>window.bad = true</script><details><summary>More</summary><p>Hidden detail</p></details>"
                : "# Heading\n\nA **printable** paragraph\n\n- [ ] A task\n\n| A | B |\n| - | - |\n| one | two |\n"
            let note = Note(notebookID: UUID(), title: "Budget <2026> & notes", body: body, format: format)
            let html = try PrintDocument.html(note: note)
            #expect(html.contains("Budget &lt;2026&gt; &amp; notes"))
            #expect(html.contains("folio-print-title"))
            #expect(html.contains("@media print"))
            #expect(html.contains("break-after: avoid"))
            #expect(!html.contains("<script"))
            #expect(!html.contains("window.bad"))
            #expect(html.contains("color-scheme: light"))
            if format == .html { #expect(html.contains("details open")) }
            else {
                #expect(html.contains("<strong>printable</strong>"))
                #expect(html.contains("<table>"))
            }
        }
    }
}

@MainActor
struct PrintingTests {
    @Test func nativePrintJobRendersCurrentTextLocalImagesAndProducesReadablePDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let bitmap = try #require(image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("picture.png"))
        let note = Note(notebookID: UUID(), title: "A printable thought",
                        body: "# Working text\n\nLatest unsaved words.\n\n![Original image](picture.png)\n\n- [ ] Follow up",
                        importedSourceURL: directory.appendingPathComponent("note.md"), importedRootURL: directory)
        let before = note
        let printer = try NotePrinter(note: note)
        defer { printer.close() }
        #expect(throws: NoteWorkflowError.self) { try printer.makeOperation() }
        try await printer.prepare()
        let view = try #require(printer.webView)
        let text = try await view.evaluateJavaScript("document.body.innerText") as? String
        #expect(text?.contains("A printable thought") == true)
        #expect(text?.contains("Latest unsaved words.") == true)
        let images = try await view.evaluateJavaScript("Array.from(document.images).filter(i => i.complete && i.naturalWidth === 8).length") as? Int
        #expect(images == 1)
        let colors = try await view.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        #expect(colors == "rgb(255, 255, 255)")
        let operation = try printer.makeOperation()
        #expect(operation.jobTitle == note.displayTitle)
        #expect(operation.showsPrintPanel)
        #expect(operation.printInfo.leftMargin == 36)
        #expect(operation.printInfo.topMargin == 36)
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 1)
        #expect(pdf.string?.contains("Latest unsaved words.") == true)
        #expect(note == before)
        printer.close()
        #expect(throws: NoteWorkflowError.self) { try printer.makeOperation() }
    }

    @Test func missingImageFailsExplicitlyInsteadOfPrintingAnIncompleteNote() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note(notebookID: UUID(), title: "Missing attachment",
                        body: "![Missing](missing.png)", importedSourceURL: directory.appendingPathComponent("note.md"),
                        importedRootURL: directory)
        let printer = try NotePrinter(note: note)
        defer { printer.close() }
        do {
            try await printer.prepare()
            Issue.record("Printing must not silently omit a missing image.")
        } catch {
            #expect(error.localizedDescription.contains("images could not be loaded"))
        }
        #expect(throws: NoteWorkflowError.self) { try printer.makeOperation() }
    }

    @Test func nativePrintOperationPaginatesLongNotesIntoSavedPDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = (1...140).map { "Paragraph \($0): Keep the entire note readable on paper, including all pages.\n\n" }.joined()
        let printer = try NotePrinter(note: Note(notebookID: UUID(), title: "Long printable note", body: body))
        defer { printer.close() }
        try await printer.prepare()
        let operation = try printer.makeOperation()
        let output = directory.appendingPathComponent("printed.pdf")
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let success = await printer.run(operation, in: window)
        #expect(success)
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 1:") == true)
        #expect(pdf.string?.contains("Paragraph 140:") == true)
    }

    @Test func printCommandRequiresANoteAndReservesTheStandardShortcut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioPrint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: defaults)
        #expect(FolioCommand.printNote.unavailableReason(in: store) == nil)
        #expect(FolioCommand.printNote.shortcut(in: store) == "⌘P")
        #expect(FolioCommand.matching("print") == [.printNote])
        store.selectedNoteID = nil
        #expect(FolioCommand.printNote.unavailableReason(in: store) != nil)
        store.printSelectedNote()
        #expect(store.errorMessage != nil)
        #expect(!store.isPreparingPrint)
        var bindings = ShortcutConfiguration.defaults
        bindings[ShortcutAction.tasks.rawValue] = ShortcutBinding(key: "p")
        #expect(throws: ShortcutError.self) { try ShortcutConfiguration.validate(bindings) }
    }
}
