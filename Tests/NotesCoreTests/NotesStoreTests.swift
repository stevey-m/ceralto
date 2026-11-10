import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct NotesStoreTests {
    private func withStore(_ body: (NotesStore, LibraryStorage) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try body(NotesStore(storage: storage), storage)
    }

    @Test func createsEditsAndPersistsNotes() throws {
        try withStore { store, storage in
            #expect(store.isLoaded)
            store.createNote()
            let id = try #require(store.selectedNoteID)
            store.update(id) { $0.title = "My idea"; $0.body = "Some words" }
            store.setTags(id, text: "Work, work, Swift")
            let loaded = try storage.load()
            let reloaded = try #require(loaded)
            let note = try #require(reloaded.notes.first { $0.id == id })
            #expect(note.title == "My idea")
            #expect(note.body == "Some words")
            #expect(note.tags == ["swift", "work"])
            #expect(!store.hasUnsavedChanges)
        }
    }

    @Test func filtersAndCreatesInCurrentCollection() throws {
        try withStore { store, _ in
            store.scope = .tag("ideas")
            store.createNote()
            #expect(store.visibleNotes.count == 1)
            #expect(store.selectedNote?.tags == ["ideas"])
            store.scope = .pinned
            store.createNote()
            #expect(store.selectedNote?.isPinned == true)
            store.addNotebook(name: "Projects")
            let notebookID = try #require(store.currentNotebookID)
            store.createNote()
            #expect(store.selectedNote?.notebookID == notebookID)
            store.update(try #require(store.selectedNoteID)) { $0.title = "Target" }
            store.query = "target"
            #expect(store.visibleNotes.count == 1)
            store.query = "absent"
            store.reconcileSelection()
            #expect(store.selectedNoteID == nil)
        }
    }

    @Test func trashRestoreAndPermanentDeletion() throws {
        try withStore { store, storage in
            store.createNote()
            let id = try #require(store.selectedNoteID)
            store.permanentlyDelete(id)
            #expect(store.library.notes.contains { $0.id == id })
            store.trash(id)
            #expect(!store.visibleNotes.contains { $0.id == id })
            store.scope = .trash
            #expect(store.visibleNotes.contains { $0.id == id })
            store.restore(id)
            #expect(!store.visibleNotes.contains { $0.id == id })
            store.trash(id)
            store.permanentlyDelete(id)
            #expect(!store.library.notes.contains { $0.id == id })
            let reloaded = try storage.load()
            #expect(reloaded?.notes.contains { $0.id == id } == false)
        }
    }

    @Test func deletingNotebookMovesActiveAndTrashedNotes() throws {
        try withStore { store, storage in
            let first = try #require(store.library.notebooks.first)
            store.addNotebook(name: "Temporary")
            let secondID = try #require(store.currentNotebookID)
            store.createNote()
            let activeID = try #require(store.selectedNoteID)
            store.createNote()
            let trashedID = try #require(store.selectedNoteID)
            store.trash(trashedID)
            store.renameNotebook(secondID, name: "Renamed")
            #expect(store.scopeTitle == "Renamed")
            store.deleteNotebook(secondID)
            #expect(store.library.notebooks.count == 1)
            #expect(store.library.notes.first { $0.id == activeID }?.notebookID == first.id)
            #expect(store.library.notes.first { $0.id == trashedID }?.notebookID == first.id)
            #expect(store.library.notes.first { $0.id == trashedID }?.deletedAt != nil)
            store.deleteNotebook(first.id)
            #expect(store.library.notebooks.count == 1)
            try storage.load()?.validate()
        }
    }

    @Test func corruptStartupBlocksWritesAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let original = Data("broken library".utf8)
        try original.write(to: url)
        let storage = LibraryStorage(url: url)
        let store = NotesStore(storage: storage)
        #expect(!store.isLoaded)
        #expect(store.errorMessage != nil)
        store.createNote()
        store.save()
        store.addNotebook(name: "Do not overwrite")
        let preserved = try Data(contentsOf: url)
        #expect(preserved == original)
        try storage.save(.starter())
        store.load()
        #expect(store.isLoaded)
        #expect(store.library.notes.count == 1)
    }

    @Test func saveFailureRetainsChangesAndRetryPersistsThem() throws {
        try withStore { store, storage in
            let id = try #require(store.selectedNoteID)
            // A directory at the destination deterministically makes atomic file replacement fail.
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            store.update(id) { $0.body = "Do not lose this edit" }
            #expect(store.hasUnsavedChanges)
            #expect(store.errorMessage != nil)
            #expect(store.selectedNote?.body == "Do not lose this edit")
            try FileManager.default.removeItem(at: storage.url)
            store.save()
            #expect(!store.hasUnsavedChanges)
            let reloaded = try storage.load()
            #expect(reloaded?.notes.first { $0.id == id }?.body == "Do not lose this edit")
        }
    }

    @Test func pinnedNotesSortBeforeRecentUnpinnedNotes() throws {
        try withStore { store, _ in
            store.createNote()
            let newID = try #require(store.selectedNoteID)
            #expect(store.visibleNotes.first?.isPinned == true)
            #expect(store.visibleNotes.last?.id == newID)
        }
    }

    @Test func historyCoalescesEditsAndRestoresWithoutLosingCurrentText() throws {
        try withStore { store, storage in
            let id = try #require(store.selectedNoteID)
            let original = try #require(store.selectedNote)
            store.update(id) { $0.body = "First edit" }
            store.update(id) { $0.body = "Latest edit" }
            let history = store.selectedNote?.history ?? []
            #expect(history.count == 1)
            #expect(history[0].body == original.body)
            store.restoreRevision(history[0], noteID: id)
            #expect(store.selectedNote?.body == original.body)
            #expect(store.selectedNote?.history?.last?.body == "Latest edit")
            let loaded = try storage.load()
            #expect(loaded?.notes.first { $0.id == id }?.history?.count == 2)
        }
    }

    @Test func historyIsBoundedAndRecordsLaterCheckpoints() {
        let notebookID = UUID()
        var note = Note(notebookID: notebookID, body: "Original")
        for index in 0..<30 {
            let previous = note
            note.body = "Edit \(index)"
            note.recordRevision(of: previous, now: Date(timeIntervalSince1970: Double(index * 301)))
        }
        #expect(note.history?.count == 20)
        #expect(note.history?.last?.body == "Edit 28")
        let previous = note
        note.isPinned.toggle()
        note.recordRevision(of: previous, force: true)
        #expect(note.history?.count == 20)
    }
}
