import Foundation
import NotesCore
import Testing

struct BackupTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func attachmentsPreserveOriginalBytesAndUseEncodedRelativeLinks() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("photo (one).jpg")
            let original = Data([1, 2, 3, 4, 5])
            try original.write(to: file)
            let note = Note(notebookID: UUID(), title: "Test", body: "Hello")
            let updated = try Attachments.adding(files: [file], to: note, directory: directory.appendingPathComponent("Attachments"))
            #expect(updated.body.contains("![photo (one).jpg]"))
            #expect(updated.body.contains("%28one%29.jpg"))
            let root = try #require(updated.importedRootURL)
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            let relative = try #require(files.first { $0.hasSuffix(".jpg") })
            let copied = try Data(contentsOf: root.appendingPathComponent(relative))
            #expect(copied == original)
        }
    }

    @Test func backupCanBeMovedAndImportedWithAttachments() throws {
        try withDirectory { directory in
            let notebook = Notebook(name: "Work")
            let file = directory.appendingPathComponent("image.jpg")
            let bytes = Data([5, 6, 7])
            try bytes.write(to: file)
            let note = try Attachments.adding(files: [file], to: Note(notebookID: notebook.id, body: "Body"),
                                             directory: directory.appendingPathComponent("OriginalAttachments"))
            let library = Library(notebooks: [notebook], notes: [note])
            let backup = directory.appendingPathComponent("Backup")
            try LibraryBackup.export(library, to: backup)
            let loaded = try LibraryStorage(url: backup.appendingPathComponent("library.json")).load()
            let portable = try #require(loaded)
            #expect(portable.notes[0].importedRootURL?.scheme == nil)
            let moved = directory.appendingPathComponent("Moved")
            try FileManager.default.moveItem(at: backup, to: moved)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("OriginalAttachments"))
            let result = try LibraryBackup.imported(from: moved, importsDirectory: directory.appendingPathComponent("Restored"))
            #expect(result.notes[0].id != note.id)
            #expect(result.notes[0].notebookID == result.notebooks[0].id)
            #expect(result.notes[0].body == note.body)
            let root = try #require(result.notes[0].importedRootURL)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            let image = try #require(paths.first { $0.hasSuffix(".jpg") })
            let restored = try Data(contentsOf: root.appendingPathComponent(image))
            #expect(restored == bytes)
        }
    }

    @Test func malformedBackupCannotEscapeItsFolder() throws {
        try withDirectory { directory in
            var library = Library.starter()
            library.notes[0].importedRootURL = URL(string: "../private/")
            library.notes[0].importedSourceURL = URL(string: "../private/file")
            let folder = directory.appendingPathComponent("Bad")
            try LibraryStorage(url: folder.appendingPathComponent("library.json")).save(library)
            #expect(throws: (any Error).self) {
                try LibraryBackup.imported(from: folder, importsDirectory: directory.appendingPathComponent("Imports"))
            }
        }
    }

    @Test func fileImportsHTMLAndMarkdownWithResourceSnapshots() throws {
        try withDirectory { directory in
            let html = directory.appendingPathComponent("page.html")
            try "<html><title>A &amp; B</title><body><h1>Page</h1><img src=\"photo.jpg\"></body></html>"
                .write(to: html, atomically: true, encoding: .utf8)
            try Data([1, 2]).write(to: directory.appendingPathComponent("photo.jpg"))
            let md = directory.appendingPathComponent("note.md")
            try "---\ntitle: Markdown title\ntags: [work]\n---\n\nBody"
                .write(to: md, atomically: true, encoding: .utf8)
            let result = try DocumentFileImport.prepare(files: [html, md], notebookID: UUID(),
                                                        importsDirectory: directory.appendingPathComponent("Imports"))
            #expect(result.notes.count == 2)
            #expect(result.notes[0].title == "A & B")
            #expect(result.notes[0].contentFormat == .html)
            #expect(result.notes[1].title == "Markdown title")
            #expect(result.notes[1].body == "Body")
            let root = try #require(result.notes[0].importedRootURL)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
        }
    }
}
