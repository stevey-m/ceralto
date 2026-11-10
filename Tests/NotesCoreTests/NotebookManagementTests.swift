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
