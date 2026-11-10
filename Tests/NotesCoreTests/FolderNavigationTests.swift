import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct FolderNavigationTests {
    @Test func mainFolderContainsItsOwnNotesAndNestedSubtopicsWithoutMixingOtherFolders() throws {
        try withStore { store, root, topic, nested, unrelated, rootNote, topicNote, nestedNote in
            store.scope = .folder("Study", [root.id])
            #expect(Set(store.outlineNotes.map(\.id)) == Set([rootNote.id, topicNote.id, nestedNote.id]))
            let folder = try #require(store.navigationFolder)
            #expect(folder.name == "Study")
            #expect(folder.notebooks.map(\.id) == [root.id])
            #expect(folder.children.map(\.name) == ["Networks"])
            #expect(folder.children.first?.children.map(\.name) == ["Practice"])
            #expect(!folder.descendants.contains(unrelated.id))
            store.scope = .notebook(nested.id)
            #expect(store.mainFolderScope == .folder("Study/Networks/Practice", [nested.id]))
            #expect(store.outlineNotes.map(\.id) == [nestedNote.id])
            #expect(!store.outlineNotes.contains { $0.notebookID == topic.id })
            store.scope = .folder("Study/Networks", [topic.id])
            #expect(Set(store.outlineNotes.map(\.id)) == Set([topicNote.id, nestedNote.id]))
            #expect(store.navigationFolder?.name == "Networks")
        }
    }

    @Test func searchAndCreationFollowTheSelectedSubtopicAndLinksRevealItsExactFolder() throws {
        try withStore { store, root, topic, nested, _, _, topicNote, nestedNote in
            store.scope = .folder("Study", [root.id, topic.id, nested.id])
            store.selectedNoteID = nestedNote.id
            store.createNote()
            #expect(store.selectedNote?.notebookID == nested.id)
            store.query = "routing"
            store.reconcileSelection()
            #expect(store.outlineNotes.map(\.id) == [topicNote.id])
            #expect(store.selectedNoteID == topicNote.id)
            store.openNote(nestedNote.id)
            #expect(store.query.isEmpty)
            #expect(store.navigationFolder?.name == "Practice")
            #expect(store.selectedNoteID == nestedNote.id)
            store.scope = .tag("review")
            #expect(store.navigationFolder == nil)
            #expect(store.outlineNotes.map(\.id) == [topicNote.id])
        }
    }

    @Test func newSubtopicsRemainVisibleWithNoNotesAndFolderMembershipDoesNotGoStale() throws {
        try withStore { store, root, _, _, _, _, _, _ in
            store.scope = .folder("Study", [root.id])
            store.addNotebook(name: "Study/New topic")
            let added = try #require(store.currentNotebookID)
            #expect(store.navigationFolder?.id == "Study/New topic")
            #expect(store.outlineNotes.isEmpty)
            store.scope = .folder("Study", [root.id])
            let folder = try #require(store.navigationFolder)
            #expect(folder.children.contains { $0.name == "New topic" && $0.notebooks.contains { $0.id == added } })
            store.scope = .folder("Study", [root.id])
            store.selectedNoteID = nil
            store.createNote()
            #expect(store.selectedNote?.notebookID == root.id)
            #expect(store.visibleNotes.contains { $0.notebookID != root.id })
        }
    }

    private func withStore(_ body: (NotesStore, Notebook, Notebook, Notebook, Notebook, Note, Note, Note) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = Notebook(name: "Study")
        let topic = Notebook(name: "Study/Networks")
        let nested = Notebook(name: "Study/Networks/Practice")
        let unrelated = Notebook(name: "Personal")
        let rootNote = Note(notebookID: root.id, title: "Overview")
        let topicNote = Note(notebookID: topic.id, title: "Routing", tags: ["review"])
        let nestedNote = Note(notebookID: nested.id, title: "Exercises")
        let hidden = Note(notebookID: unrelated.id, title: "Other")
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [root, topic, nested, unrelated], notes: [rootNote, topicNote, nestedNote, hidden]))
        try body(NotesStore(storage: storage), root, topic, nested, unrelated, rootNote, topicNote, nestedNote)
    }
}
