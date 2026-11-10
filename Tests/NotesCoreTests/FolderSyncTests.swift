import Foundation
import NotesCore
import Testing

struct FolderSyncTests {
    private func fixture(_ test: (URL, Library) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = Notebook(name: "Personal")
        let note = Note(notebookID: notebook.id, title: "Offline thought", body: "Original")
        try test(root, Library(notebooks: [notebook], notes: [note]))
    }

    @Test func readerPullsWithoutPublishingAndKeepsAnOfflineCopy() throws {
        try fixture { root, initial in
            let folder = root.appendingPathComponent("Shared")
            var mac = try FolderSync.synchronize(initial, folder: folder, assets: root.appendingPathComponent("Mac")).library
            let reader = Library(notebooks: [Notebook(name: "Empty")])
            let before = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Folio Sync/snapshots").path).count
            let ipad = try FolderSync.pull(reader, folder: folder, assets: root.appendingPathComponent("iPad")).library
            let after = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Folio Sync/snapshots").path).count
            #expect(before == after)
            #expect(ipad.notes == mac.notes)
            mac.notes[0].body = "Written while disconnected"
            mac.notes[0].updatedAt = Date().addingTimeInterval(10)
            mac = try FolderSync.synchronize(mac, folder: folder, assets: root.appendingPathComponent("Mac")).library
            let refreshed = try FolderSync.pull(ipad, folder: folder, assets: root.appendingPathComponent("iPad")).library
            #expect(refreshed.notes[0].body == "Written while disconnected")
            let cache = LibraryStorage(url: root.appendingPathComponent("cache/library.json"))
            try cache.save(refreshed)
            try FileManager.default.removeItem(at: folder)
            let offline = try cache.load()
            #expect(offline?.notes[0].body == mac.notes[0].body)
        }
    }

    @Test func concurrentEditsPreserveBothVersionsWithoutRepeatedCopies() throws {
        try fixture { root, initial in
            let folder = root.appendingPathComponent("Shared")
            var first = try FolderSync.synchronize(initial, folder: folder, assets: root.appendingPathComponent("A")).library
            var second = try FolderSync.pull(Library(notebooks: [Notebook(name: "Empty")]),
                folder: folder, assets: root.appendingPathComponent("B")).library
            first.notes[0].body = "Mac A offline edit"
            first.notes[0].updatedAt = Date(timeIntervalSince1970: 100)
            second.notes[0].body = "Mac B offline edit"
            second.notes[0].updatedAt = Date(timeIntervalSince1970: 200)
            first = try FolderSync.synchronize(first, folder: folder, assets: root.appendingPathComponent("A")).library
            let conflict = try FolderSync.synchronize(second, folder: folder, assets: root.appendingPathComponent("B"))
            #expect(conflict.conflicts == 1)
            #expect(Set(conflict.library.notes.map(\.body)) == ["Mac A offline edit", "Mac B offline edit"])
            #expect(conflict.library.notes.allSatisfy { $0.tags.contains("sync-conflict") })
            let published = try FolderSync.synchronize(conflict.library, folder: folder, assets: root.appendingPathComponent("B")).library
            let converged = try FolderSync.synchronize(first, folder: folder, assets: root.appendingPathComponent("A")).library
            #expect(Set(published.notes.map(\.id)) == Set(converged.notes.map(\.id)))
            #expect(converged.notes.count == 2)
        }
    }

    @Test func permanentDeletionIsNotResurrectedByAStaleDevice() throws {
        try fixture { root, initial in
            let folder = root.appendingPathComponent("Shared")
            let stale = try FolderSync.synchronize(initial, folder: folder, assets: root.appendingPathComponent("A")).library
            var deleting = stale
            deleting.notes = []
            let deleted = try FolderSync.synchronize(deleting, folder: folder, assets: root.appendingPathComponent("A")).library
            #expect(deleted.notes.isEmpty)
            let rejoined = try FolderSync.synchronize(stale, folder: folder, assets: root.appendingPathComponent("B")).library
            #expect(rejoined.notes.isEmpty)
        }
    }

    @Test func deletedNotebookDoesNotReturnAfterNotesAreMoved() throws {
        try fixture { root, initial in
            let folder = root.appendingPathComponent("Shared")
            let destination = Notebook(name: "Archive")
            var first = initial
            first.notebooks.append(destination)
            first = try FolderSync.synchronize(first, folder: folder, assets: root.appendingPathComponent("A")).library
            let oldID = initial.notebooks[0].id
            first.notes[0].notebookID = destination.id
            first.notes[0].updatedAt = Date().addingTimeInterval(10)
            first.notebooks.removeAll { $0.id == oldID }
            let result = try FolderSync.synchronize(first, folder: folder, assets: root.appendingPathComponent("A")).library
            #expect(result.notebooks.map(\.id) == [destination.id])
            #expect(result.notes[0].notebookID == destination.id)
        }
    }

    @Test func attachmentsAreCopiedLocallyAndRemainReadableOffline() throws {
        try fixture { root, initial in
            let file = root.appendingPathComponent("original.jpg")
            let bytes = Data([1, 2, 3, 4, 5])
            try bytes.write(to: file)
            var mac = initial
            mac.notes[0] = try Attachments.adding(files: [file], to: mac.notes[0], directory: root.appendingPathComponent("Originals"))
            let folder = root.appendingPathComponent("Shared")
            _ = try FolderSync.synchronize(mac, folder: folder, assets: root.appendingPathComponent("A"))
            let reader = try FolderSync.pull(Library(notebooks: [Notebook(name: "Empty")]),
                folder: folder, assets: root.appendingPathComponent("B")).library
            let note = try #require(reader.notes.first)
            let resources = ImportedResources(source: try #require(note.importedSourceURL), root: try #require(note.importedRootURL))
            let page = try FormattedPage(markdown: note.body)
            let reference = try #require(page.blocks.flatMap(\.runs).first { $0.image != nil }?.image)
            let local = try #require(resources.localURL(for: reference))
            try FileManager.default.removeItem(at: folder)
            let copied = try Data(contentsOf: local)
            #expect(copied == bytes)
        }
    }

    @Test func damagedSnapshotsFailBeforeReplacingLocalData() throws {
        try fixture { root, initial in
            let folder = root.appendingPathComponent("Shared")
            _ = try FolderSync.synchronize(initial, folder: folder, assets: root.appendingPathComponent("A"))
            let snapshots = folder.appendingPathComponent("Folio Sync/snapshots")
            let directories = try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
            let snapshot = try #require(directories.first)
            try Data("damaged".utf8).write(to: snapshot.appendingPathComponent("library.json"))
            #expect(throws: (any Error).self) {
                try FolderSync.pull(initial, folder: folder, assets: root.appendingPathComponent("B"))
            }
            #expect(initial.notes[0].body == "Original")
        }
    }
}
