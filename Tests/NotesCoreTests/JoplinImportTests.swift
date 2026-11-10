import Foundation
import NotesCore
import Testing
@testable import Folio

struct JoplinImportTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func parsesJoplinMetadataAndPreservesBody() throws {
        let source = """
        ---
        title: "An idea: \\"quoted\\""
        created: 2021-05-01 16:40:00Z
        updated: 2021-06-17 23:59:00Z
        tags:
          - Work
          - "two words"
          - work
        source: https://example.com
        completed?: no
        ---

        # Body

        - [ ] A task
        """
        let note = try JoplinImport.parse(source, filename: "fallback", notebookID: UUID())
        #expect(note.title == "An idea: \"quoted\"")
        #expect(note.tags == ["two words", "work"])
        #expect(note.body == "# Body\n\n- [ ] A task")
        let formatter = ISO8601DateFormatter()
        #expect(note.createdAt == formatter.date(from: "2021-05-01T16:40:00Z"))
        #expect(note.updatedAt == formatter.date(from: "2021-06-17T23:59:00Z"))
    }

    @Test func supportsYAMLBlockScalarsInlineTagsAndCRLF() throws {
        let source = "---\r\ntitle: >-\r\n  A longer\r\n  title\r\ntags: [One, 'Two: three']\r\ncreated: 1970-01-01 00:00Z\r\n---\r\n\r\n\r\nText\r\n"
        let note = try JoplinImport.parse(source, filename: "fallback", notebookID: UUID())
        #expect(note.title == "A longer title")
        #expect(note.tags == ["one", "two: three"])
        #expect(note.createdAt == Date(timeIntervalSince1970: 0))
        #expect(note.body == "\nText\n")
    }

    @Test func plainMarkdownAndMissingMetadataUseFilename() throws {
        let plain = try JoplinImport.parse("# Hello\n", filename: "Filename", notebookID: UUID())
        #expect(plain.title == "Filename")
        #expect(plain.body == "# Hello\n")
        let missing = try JoplinImport.parse("---\nauthor: Someone\n---\nBody", filename: "Fallback", notebookID: UUID())
        #expect(missing.title == "Fallback")
        #expect(missing.body == "Body")
        let empty = try JoplinImport.parse("---\ntitle: Empty\n---", filename: "fallback", notebookID: UUID())
        #expect(empty.body.isEmpty)
    }

    @Test func rejectsMalformedMetadata() {
        for source in [
            "---\ntitle: Missing delimiter",
            "---\ntitle: [wrong type]\n---\nBody",
            "---\ntags: not-a-list\n---\nBody",
            "---\ntitle: First\ntitle: Duplicate\n---\nBody",
            "---\ncreated: not-a-date\n---\nBody",
            "---\ntags: [one, [nested]]\n---\nBody"
        ] {
            #expect(throws: (any Error).self) {
                try JoplinImport.parse(source, filename: "invalid", notebookID: UUID())
            }
        }
    }

    @Test func importsNestedNotebooksAndCopiesResourcesIndependently() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("Export")
            try write("---\ntitle: Root note\n---\n\nRoot", to: root.appendingPathComponent("root.md"))
            try write("---\ntitle: Nested\n---\n\n![Photo](../../_resources/photo.png)",
                      to: root.appendingPathComponent("Work/Projects/note.md"))
            try write("attachment bytes", to: root.appendingPathComponent("_resources/photo.png"))
            try write("not a note", to: root.appendingPathComponent("_resources/document.md"))
            let result = try JoplinImport.prepare(
                folder: root, importsDirectory: directory.appendingPathComponent("Imports")
            )
            #expect(result.notes.count == 2)
            #expect(Set(result.notebooks.map(\.name)) == ["Export", "Work/Projects"])
            let note = try #require(result.notes.first { $0.title == "Nested" })
            let sourceURL = try #require(note.importedSourceURL)
            let resourceURL = try #require(URL(string: "../../_resources/photo.png",
                                              relativeTo: sourceURL.deletingLastPathComponent()))
            try FileManager.default.removeItem(at: root)
            let copiedResource = try String(contentsOf: resourceURL.absoluteURL, encoding: .utf8)
            #expect(copiedResource == "attachment bytes")
            #expect(FileManager.default.fileExists(atPath: sourceURL.path))
            #expect(note.importedRootURL == result.snapshotURL)
        }
    }

    @Test func malformedFolderDoesNotCreateSnapshot() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("Export")
            try write("---\ntitle: Good\n---\nBody", to: root.appendingPathComponent("a.md"))
            try write("---\ntags: invalid\n---\nBody", to: root.appendingPathComponent("z.md"))
            let imports = directory.appendingPathComponent("Imports")
            #expect(throws: (any Error).self) {
                try JoplinImport.prepare(folder: root, importsDirectory: imports)
            }
            #expect(!FileManager.default.fileExists(atPath: imports.path))
        }
    }

    @Test func rejectsEmptyFoldersAndSymlinks() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("Export")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let imports = directory.appendingPathComponent("Imports")
            #expect(throws: (any Error).self) {
                try JoplinImport.prepare(folder: root, importsDirectory: imports)
            }
            try write("Outside", to: directory.appendingPathComponent("outside.md"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("link.md"),
                withDestinationURL: directory.appendingPathComponent("outside.md")
            )
            #expect(throws: (any Error).self) {
                try JoplinImport.prepare(folder: root, importsDirectory: imports)
            }
            #expect(!FileManager.default.fileExists(atPath: imports.path))
        }
    }

    @MainActor @Test func commitsAndReloadsImportsWithoutReplacingExistingNotes() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("Export")
            try write("---\ntitle: Imported\ntags: [Joplin]\n---\n\nHello",
                      to: root.appendingPathComponent("note.md"))
            let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
            let store = NotesStore(storage: storage)
            let existing = store.library.notes
            let result = try JoplinImport.prepare(folder: root, importsDirectory: directory.appendingPathComponent("Imports"))
            try store.commitJoplinImport(result)
            #expect(store.library.notes.count == existing.count + 1)
            #expect(store.library.notes.contains(existing[0]))
            let loaded = try storage.load()
            #expect(loaded == store.library)
            #expect(store.selectedNote?.title == "Imported")
            #expect(store.selectedNote?.tags == ["joplin"])
        }
    }

    @MainActor @Test func failedLibrarySaveRollsBackImportAndCleansSnapshot() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("Export")
            try write("---\ntitle: Imported\n---\n\nHello", to: root.appendingPathComponent("note.md"))
            let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
            let store = NotesStore(storage: storage)
            let original = store.library
            let result = try JoplinImport.prepare(folder: root, importsDirectory: directory.appendingPathComponent("Imports"))
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.commitJoplinImport(result) }
            #expect(store.library == original)
            #expect(!FileManager.default.fileExists(atPath: result.snapshotURL.path))
        }
    }

    @Test func existingLibraryWithoutImportFieldsStillLoads() throws {
        let library = Library.starter()
        let encoded = try JSONEncoder().encode(library)
        let decoded = try JSONDecoder().decode(Library.self, from: encoded)
        #expect(decoded == library)
        #expect(decoded.notes[0].importedSourceURL == nil)
    }
}
