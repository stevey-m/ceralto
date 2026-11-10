import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct CaptureSearchVaultTests {
    @Test func captureUsesOneInboxWithoutChangingTheOpenNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = LibraryStorage(url: folder.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage)
        let selection = store.selectedNoteID
        let first = try store.capture(title: "A thought", body: "Literal **words**, not markup")
        _ = try store.capture(title: "", body: "Another thought")
        #expect(store.selectedNoteID == selection)
        #expect(store.library.notebooks.filter { $0.name == "Inbox" }.count == 1)
        let persisted = try storage.load()
        let loaded = try #require(persisted)
        let note = try #require(loaded.notes.first { $0.id == first })
        #expect(note.contentFormat == .formatted)
        let page = try FormattedPage(markdown: note.body)
        #expect(page.blocks.flatMap(\.runs).map(\.text).joined() == "Literal **words**, not markup")
        #expect(!page.blocks.flatMap(\.runs).contains { $0.bold })
    }

    @Test func failedCaptureDoesNotCommitOrClearTheDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = LibraryStorage(url: folder.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage)
        let before = store.library
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.capture(title: "Keep me", body: "Draft") }
        #expect(store.library == before)
    }

    @Test func finderSearchesNotebooksTagsAndHTMLTextButNotTrash() {
        let notebook = Notebook(name: "Travel")
        let title = Note(notebookID: notebook.id, title: "Cafe", body: "Paris", tags: ["summer"])
        let html = Note(notebookID: notebook.id, title: "Receipt", body: "<p>Caf&eacute; total</p>", format: .html)
        let trash = Note(notebookID: notebook.id, title: "Cafe old", deletedAt: Date())
        let library = Library(notebooks: [notebook], notes: [html, trash, title])
        #expect(NoteSearch.find("cafe", in: library).first?.id == title.id)
        #expect(NoteSearch.find("Travel summer", in: library).map(\.id) == [title.id])
        let result = NoteSearch.find("cafe total", in: library)
        #expect(result.map(\.id) == [html.id])
        #expect(result[0].snippet == "Caf\u{e9} total")
        #expect(html.wordCount == 2)
    }

    @Test func openVaultIncludesReadableMarkdownMetadataAndOriginalAttachments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("photo.jpg")
        let bytes = Data([10, 20, 30])
        try bytes.write(to: image)
        let notebook = Notebook(name: "Work/Ideas")
        var note = Note(notebookID: notebook.id, title: "A portable thought", body: "**Mine**", tags: ["ideas"], format: .formatted)
        note = try Attachments.adding(files: [image], to: note, directory: folder.appendingPathComponent("Assets"))
        let destination = folder.appendingPathComponent("Vault")
        try MarkdownVault.export(Library(notebooks: [notebook], notes: [note]), to: destination)
        let enumerator = try #require(FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }
        let document = try #require(files.first { $0.pathExtension == "md" })
        let text = try String(contentsOf: document, encoding: .utf8)
        #expect(text.contains("title: A portable thought"))
        #expect(text.contains("**Mine**"))
        #expect(text.contains("tags:"))
        let original = try #require(files.first { $0.pathExtension == "jpg" })
        let copied = try Data(contentsOf: original)
        #expect(copied == bytes)
        #expect(throws: (any Error).self) {
            try MarkdownVault.export(Library(notebooks: [notebook], notes: [note]), to: destination)
        }
    }
}
