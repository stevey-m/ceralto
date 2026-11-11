import Foundation
import NotesCore
import Testing

struct EncryptedBackupTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func encryptedRoundTripPreservesHistoryTrashAndOriginalAttachments() throws {
        try withDirectory { directory in
            let notebook = Notebook(name: "Private notebook")
            let original = Note(notebookID: notebook.id, title: "Previous title", body: "Previous contents")
            let resource = directory.appendingPathComponent("private attachment.bin")
            let bytes = Data((0..<255).map(UInt8.init))
            try bytes.write(to: resource)
            var note = try Attachments.adding(files: [resource], to: original,
                                              directory: directory.appendingPathComponent("Attachments"))
            note.history = [NoteRevision(note: original)]
            note.deletedAt = Date(timeIntervalSince1970: 1_000)
            let library = Library(notebooks: [notebook], notes: [note])
            let archive = directory.appendingPathComponent("complete.deltosbackup")
            let password = UUID().uuidString
            try EncryptedBackup.export(library, to: archive, password: password)
            let encrypted = try Data(contentsOf: archive)
            #expect(encrypted.range(of: Data(note.title.utf8)) == nil)
            #expect(encrypted.range(of: Data("private attachment.bin".utf8)) == nil)
            #expect(encrypted.range(of: Data("library.json".utf8)) == nil)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("Attachments"))
            let imports = directory.appendingPathComponent("Restored")
            let restored = try EncryptedBackup.imported(from: archive, password: password, importsDirectory: imports)
            #expect(restored.notes.count == 1)
            let copy = try #require(restored.notes.first)
            #expect(copy.id != note.id)
            #expect(copy.notebookID == restored.notebooks[0].id)
            #expect(copy.body == note.body)
            #expect(copy.history == note.history)
            #expect(copy.deletedAt == note.deletedAt)
            let root = try #require(copy.importedRootURL)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            let attachment = try #require(paths.first { $0.hasSuffix(".bin") })
            let actual = try Data(contentsOf: root.appendingPathComponent(attachment))
            #expect(actual == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).count == 1)
        }
    }

    @Test func authenticationRejectsWrongPasswordAndTamperingWithoutCreatingImports() throws {
        try withDirectory { directory in
            let archive = directory.appendingPathComponent("archive.deltosbackup")
            let password = UUID().uuidString
            try EncryptedBackup.export(.starter(), to: archive, password: password)
            let original = try Data(contentsOf: archive)
            let imports = directory.appendingPathComponent("Imports")
            #expect(throws: (any Error).self) {
                try EncryptedBackup.imported(from: archive, password: UUID().uuidString, importsDirectory: imports)
            }

            for offset in [8, 24, 28, original.count - 1] {
                var corrupted = original
                corrupted[offset] ^= 0x01
                try corrupted.write(to: archive)
                #expect(throws: (any Error).self) {
                    try EncryptedBackup.imported(from: archive, password: password, importsDirectory: imports)
                }
                #expect(!FileManager.default.fileExists(atPath: imports.path))
            }
            for length in [0, 27, 55] {
                try original.prefix(length).write(to: archive)
                #expect(throws: (any Error).self) {
                    try EncryptedBackup.imported(from: archive, password: password, importsDirectory: imports)
                }
            }
        }
    }

    @Test func restoredInternalLinksTargetCopiesAndCodeExamplesStayLiteral() throws {
        try withDirectory { directory in
            let notebook = Notebook(name: "Links")
            let target = Note(notebookID: notebook.id, title: "Target")
            let url = "folio-note://" + target.id.uuidString
            var source = Note(notebookID: notebook.id, title: "Source",
                              body: "[Target](\(url))\n\n`[Example](\(url))`")
            source.history = [NoteRevision(note: source)]
            let archive = directory.appendingPathComponent("links.deltosbackup")
            let password = UUID().uuidString
            try EncryptedBackup.export(Library(notebooks: [notebook], notes: [source, target]), to: archive, password: password)
            let result = try EncryptedBackup.imported(from: archive, password: password,
                                                     importsDirectory: directory.appendingPathComponent("Imports"))
            let copy = try #require(result.notes.first { $0.title == "Source" })
            let copiedTarget = try #require(result.notes.first { $0.title == "Target" })
            #expect(copy.body.contains("[Target](folio-note://\(copiedTarget.id.uuidString))"))
            #expect(copy.body.contains("`[Example](\(url))`"))
            #expect(copy.history?.first?.body == copy.body)
        }
    }

    @Test func exportsAreRandomizedNeverOverwriteAndRejectWeakPasswordsAndLinks() throws {
        try withDirectory { directory in
            let first = directory.appendingPathComponent("first.deltosbackup")
            let second = directory.appendingPathComponent("second.deltosbackup")
            let password = UUID().uuidString
            #expect(throws: (any Error).self) { try EncryptedBackup.export(.starter(), to: first, password: "") }
            #expect(!FileManager.default.fileExists(atPath: first.path))
            try EncryptedBackup.export(.starter(), to: first, password: password)
            let original = try Data(contentsOf: first)
            #expect(throws: (any Error).self) { try EncryptedBackup.export(.starter(), to: first, password: password) }
            #expect(try Data(contentsOf: first) == original)
            try EncryptedBackup.export(.starter(), to: second, password: password)
            #expect(try Data(contentsOf: second) != original)
            let notebook = Notebook(name: "Resources")
            let root = directory.appendingPathComponent("resources")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("source.md")
            try Data().write(to: source)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: first)
            let note = Note(notebookID: notebook.id, importedSourceURL: source, importedRootURL: root)
            let unsafe = directory.appendingPathComponent("unsafe.deltosbackup")
            #expect(throws: (any Error).self) {
                try EncryptedBackup.export(Library(notebooks: [notebook], notes: [note]), to: unsafe, password: password)
            }
            #expect(!FileManager.default.fileExists(atPath: unsafe.path))
        }
    }
}
