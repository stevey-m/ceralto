import Foundation
import NotesCore
import Testing
@testable import Folio

struct NotebookManagementTests {
    @Test func branchRenamePreservesIDsNotesAndAllDescendantsWithoutMovingSimilarNames() throws {
        let parent = Notebook(name: "Study")
        let child = Notebook(name: "Study/Networks")
        let deep = Notebook(name: "Study/Networks/Labs")
        let other = Notebook(name: "Study-old")
        let note = Note(notebookID: deep.id, title: "Keep", tags: ["keep"], deletedAt: Date())
        let library = Library(notebooks: [parent, child, deep, other], notes: [note])
        let moved = try NotebookManagement.renaming(library, branch: "Study", to: "Work/Learning")
        #expect(moved.notebooks.map(\.name) == ["Work/Learning", "Work/Learning/Networks", "Work/Learning/Networks/Labs", "Study-old"])
        #expect(moved.notebooks.map(\.id) == library.notebooks.map(\.id))
        #expect(moved.notes == library.notes)
    }

    @Test func syntheticBranchCanMoveAndCollisionsCyclesAndInvalidPathsAreRejected() throws {
        let library = Library(notebooks: [Notebook(name: "Study/Networks/Labs"), Notebook(name: "Work/Existing")])
        let moved = try NotebookManagement.renaming(library, branch: "Study", to: "Learning")
        #expect(moved.notebooks.first?.name == "Learning/Networks/Labs")
        for path in ["Study/Child", "Work", "work", "../Escape", "/Absolute", "Bad//Path", " Bad /Path"] {
            #expect(throws: (any Error).self) { try NotebookManagement.renaming(library, branch: "Study", to: path) }
        }
        #expect(throws: (any Error).self) { try NotebookManagement.renaming(library, branch: "Missing", to: "New") }
    }

    @Test func movingNotesToSyntheticParentCreatesNotebookWithoutChangingContentOrIDs() throws {
        let notebook = Notebook(name: "Study/Networks")
        let note = Note(notebookID: notebook.id, title: "Keep", body: "Original")
        let library = Library(notebooks: [notebook], notes: [note])
        let moved = try NotebookManagement.movingNotes([note.id], in: library, to: "Study")
        #expect(moved.notebooks.count == 2)
        #expect(moved.notes[0].id == note.id)
        #expect(moved.notes[0].body == note.body)
        #expect(moved.notes[0].notebookID == moved.notebooks.last?.id)
        #expect(throws: (any Error).self) { try NotebookManagement.movingNotes([UUID()], in: library, to: "Study") }
    }
}

@MainActor
struct NotebookManagementStoreTests {
    @Test func bulkMoveTagTrashAndRestorePersistOnlySelectedNotes() throws {
        try fixture { store, storage in
            let first = try #require(store.library.notes.first)
            let destination = try #require(store.library.notebooks.first { $0.name == "Work" })
            let second = Note(notebookID: first.notebookID, title: "Second", body: "Body", tags: ["keep"])
            let untouched = Note(notebookID: first.notebookID, title: "Untouched")
            var seed = store.library
            seed.notes += [second, untouched]
            try storage.save(seed)
            store.load()
            let ids: Set<UUID> = [first.id, second.id]
            try store.applyBulkAction(.move(destination.id), to: ids)
            try store.applyBulkAction(.addTags(["new", " NEW ", "idea"]), to: ids)
            let moved = store.library.notes.filter { ids.contains($0.id) }
            #expect(moved.allSatisfy { $0.notebookID == destination.id })
            #expect(moved.allSatisfy { $0.tags.contains("new") && $0.tags.contains("idea") })
            #expect(moved.first { $0.id == second.id }?.tags.contains("keep") == true)
            #expect(moved.first { $0.id == second.id }?.body == "Body")
            #expect(store.library.notes.first { $0.id == untouched.id } == untouched)
            try store.applyBulkAction(.trash, to: ids)
            #expect(store.library.notes.filter { ids.contains($0.id) }.allSatisfy { $0.deletedAt != nil })
            try store.applyBulkAction(.restore, to: ids)
            #expect(store.library.notes.allSatisfy { $0.deletedAt == nil })
            let persisted = try storage.load()
            #expect(persisted == store.library)
        }
    }

    @Test func staleMixedTrashAndReadOnlyBulkRequestsCannotPartiallyChangeNotes() throws {
        try fixture { store, storage in
            let note = try #require(store.library.notes.first)
            let before = store.library
            for action: BulkNoteAction in [.trash, .addTags(["tag"]), .move(UUID()), .restore] {
                #expect(throws: (any Error).self) { try store.applyBulkAction(action, to: [note.id, UUID()]) }
                #expect(store.library == before)
            }
            #expect(throws: (any Error).self) { try store.applyBulkAction(.move(UUID()), to: [note.id]) }
            #expect(throws: (any Error).self) { try store.applyBulkAction(.addTags([" "]), to: [note.id]) }
            let readOnly = NotesStore(storage: storage, readOnly: true)
            #expect(throws: (any Error).self) { try readOnly.applyBulkAction(.trash, to: [note.id]) }
            #expect(readOnly.library == before)
            store.trash(note.id)
            let trashed = store.library
            #expect(throws: (any Error).self) { try store.applyBulkAction(.addTags(["tag"]), to: [note.id]) }
            #expect(store.library == trashed)
        }
    }

    @Test func selectedExportCopiesAttachmentsAndLeavesUnselectedNotesAndExistingFoldersAlone() throws {
        try fixture { store, storage in
            let note = try #require(store.library.notes.first)
            let root = storage.url.deletingLastPathComponent()
            let resources = root.appendingPathComponent("resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            let image = resources.appendingPathComponent("image.png")
            try Data([1, 2, 3]).write(to: image)
            var seed = store.library
            seed.notes[0].body = "![Picture](image.png)"
            seed.notes[0].importedRootURL = resources
            seed.notes[0].importedSourceURL = resources.appendingPathComponent("source.md")
            seed.notes.append(Note(notebookID: note.notebookID, title: "Do not export", body: "UNSELECTED"))
            try storage.save(seed)
            store.load()
            let destination = root.appendingPathComponent("selected")
            try store.exportSelectedNotes([note.id], to: destination)
            let enumerator = try #require(FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil))
            let files = enumerator.compactMap { $0 as? URL }
            let images = files.filter { $0.lastPathComponent == "image.png" }
            #expect(images.count == 1)
            let exportedImage = try Data(contentsOf: #require(images.first))
            #expect(exportedImage == Data([1, 2, 3]))
            let markdown = files.filter { $0.pathExtension == "md" }
            #expect(markdown.count == 1)
            let content = try String(contentsOf: #require(markdown.first), encoding: .utf8)
            #expect(content.contains("![Picture](image.png)"))
            #expect(!content.contains("UNSELECTED"))
            #expect(throws: (any Error).self) { try store.exportSelectedNotes([note.id], to: destination) }
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(throws: (any Error).self) { try store.exportSelectedNotes([note.id, UUID()], to: root.appendingPathComponent("stale")) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stale").path))
            #expect(store.library == seed)
        }
    }

    @Test func duplicateImportedNotebookCanBeRenamedIndividuallyBeforePathBasedMoves() throws {
        try fixture { store, storage in
            let duplicate = Notebook(name: "Work")
            var candidate = store.library
            candidate.notebooks.append(duplicate)
            try storage.save(candidate)
            store.load()
            let note = try #require(store.library.notes.first)
            #expect(!store.moveNotes([note.id], to: "Work"))
            #expect(store.renameNotebook(duplicate.id, name: "Other work"))
            #expect(store.library.notebooks.filter { $0.name == "Work" }.count == 1)
            #expect(store.moveNotes([note.id], to: "Work"))
        }
    }

    @Test func dragPayloadMovesNotesAndNotebookBranchesAndPersistsThem() throws {
        try fixture { store, storage in
            let note = try #require(store.library.notes.first)
            #expect(store.acceptNotebookDrop(["deltos-note:" + note.id.uuidString], on: "Work"))
            #expect(store.library.notebooks.first { $0.id == store.library.notes[0].notebookID }?.name == "Work")
            #expect(store.acceptNotebookDrop(["deltos-folder:Study"], on: "Work"))
            #expect(store.library.notebooks.contains { $0.name == "Work/Study/Networks" })
            let loaded = try storage.load()
            #expect(loaded == store.library)
            let before = store.library
            #expect(!store.acceptNotebookDrop(["deltos-folder:Work"], on: "Work/Study"))
            #expect(store.library == before)
            #expect(store.errorMessage != nil)
        }
    }

    @Test func diskFailureDoesNotPartiallyRenameOrMoveTheInMemoryLibrary() throws {
        try fixture { store, storage in
            let before = store.library
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            #expect(!store.renameNotebookBranch("Study", to: "Learning"))
            #expect(store.library == before)
            #expect(!store.moveNotes([before.notes[0].id], to: "Work"))
            #expect(store.library == before)
            #expect(!store.addNotebook(name: "New"))
            #expect(store.library == before)
            for action: BulkNoteAction in [.trash, .addTags(["new"]), .move(before.notebooks[1].id)] {
                #expect(throws: (any Error).self) { try store.applyBulkAction(action, to: [before.notes[0].id]) }
                #expect(store.library == before)
            }
        }
    }

    private func fixture(_ action: (NotesStore, LibraryStorage) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosManagement-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Study/Networks")
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook, Notebook(name: "Work")],
                                 notes: [Note(notebookID: notebook.id, body: "Keep this")]))
        try action(NotesStore(storage: storage, preferences: defaults), storage)
    }
}
