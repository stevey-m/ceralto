import AppKit
import Foundation
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@MainActor
struct SmartFolderTests {
    @Test func savedFoldersRestoreWithoutChangingTheLibraryAndDeletingOnlyRemovesRules() throws {
        try withStore { store, storage, _, first, _, _ in
            let original = try Data(contentsOf: storage.url)
            let folder = SmartFolder(name: "Review next", query: "notebook:Work tag:review")
            try store.saveSmartFolder(folder)
            #expect(store.scope == .smart(folder.id))
            #expect(store.visibleNotes.map(\.id) == [first.id])
            #expect(store.selectedNoteID == first.id)
            let restarted = NotesStore(storage: storage)
            #expect(restarted.errorMessage == nil)
            #expect(restarted.smartFolders == [folder])
            restarted.scope = .smart(folder.id)
            #expect(restarted.visibleNotes.map(\.id) == [first.id])
            restarted.deleteSmartFolder(folder.id)
            #expect(restarted.smartFolders.isEmpty)
            #expect(restarted.scope == .all)
            let after = try Data(contentsOf: storage.url)
            #expect(after == original)
            let final = try store.smartFolderStorage.load()
            #expect(final.isEmpty)
            #expect(restarted.library.notes.count == 3)
        }
    }

    @Test func membershipUpdatesAfterTagsPinningMovesTrashAndRestoration() throws {
        try withStore { store, _, notebook, first, second, other in
            let folder = SmartFolder(name: "Pinned review", query: "tag:review is:pinned notebook:Work")
            try store.saveSmartFolder(folder)
            #expect(store.visibleNotes.map(\.id) == [first.id])
            store.update(second.id) { $0.tags = ["review"]; $0.isPinned = true }
            #expect(Set(store.visibleNotes.map(\.id)) == Set([first.id, second.id]))
            #expect(store.smartFolderCount(folder) == 2)
            store.update(second.id) { $0.notebookID = other.notebookID }
            #expect(store.visibleNotes.map(\.id) == [first.id])
            store.update(second.id) { $0.notebookID = notebook.id }
            store.trash(first.id)
            #expect(store.visibleNotes.map(\.id) == [second.id])
            store.restore(first.id)
            #expect(store.smartFolderCount(folder) == 2)
            store.update(first.id) { $0.isPinned = false }
            #expect(store.visibleNotes.map(\.id) == [second.id])
            store.setTags(second.id, text: "archive")
            #expect(store.visibleNotes.isEmpty)
            #expect(store.library.notes.count == 3)
        }
    }

    @Test func refiningAndOpeningTabsRetainsTheSavedSearchWhenTheNoteMatches() throws {
        try withStore { store, _, _, first, second, other in
            let folder = SmartFolder(name: "Work", query: "notebook:Work")
            try store.saveSmartFolder(folder)
            store.query = "title:Plan"
            store.reconcileSelection()
            #expect(store.visibleNotes.map(\.id) == [first.id])
            store.openNoteInNewTab(first.id)
            #expect(store.scope == .smart(folder.id))
            #expect(store.query == "title:Plan")
            store.query = ""
            store.openNoteInNewTab(second.id)
            store.openNote(first.id)
            #expect(store.scope == .smart(folder.id))
            #expect(store.workspace.tabs.contains(second.id))
            store.query = "tag:"
            #expect(store.searchError != nil)
            #expect(store.visibleNotes.isEmpty)
            #expect(store.smartFolderCount(folder) == 2)
            store.query = ""
            store.openNote(other.id)
            #expect(store.activeSmartFolder == nil)
            #expect(store.selectedNoteID == other.id)
        }
    }

    @Test func editingPreservesFolderIdentityAndNewNotesUseARealNotebook() throws {
        try withStore { store, storage, notebook, first, _, _ in
            let folder = SmartFolder(name: "Review", query: "tag:review")
            try store.saveSmartFolder(folder)
            let edited = SmartFolder(id: folder.id, name: "Pinned", query: "is:pinned")
            try store.saveSmartFolder(edited)
            #expect(store.smartFolders == [edited])
            #expect(store.selectedNoteID == first.id)
            store.createNote()
            #expect(store.scope == .all)
            #expect(store.selectedNote?.notebookID == notebook.id)
            #expect(store.selectedNote?.isPinned == false)
            #expect(store.selectedNote?.tags.isEmpty == true)
            #expect(store.visibleNotes.contains { $0.id == store.selectedNoteID })
            let saved = try storage.load()
            #expect(saved?.notes.count == 4)
        }
    }

    @Test func savingFromACollectionIncludesItsScopeAndTheCurrentRefinement() throws {
        try withStore { store, _, notebook, first, _, _ in
            store.scope = .folder("Work", [notebook.id])
            store.query = "tag:review"
            store.draftSmartFolder()
            let draft = try #require(store.smartFolderDraft)
            #expect(draft.query == #"notebook:"Work" tag:review"#)
            #expect(store.smartFolderCount(draft) == 1)
            store.scope = .pinned
            store.draftSmartFolder()
            #expect(store.smartFolderDraft?.query == "is:pinned tag:review")
            store.scope = .tag("review")
            store.query = ""
            store.draftSmartFolder()
            #expect(store.smartFolderDraft?.query == #"tag:"review""#)
            let folder = SmartFolder(name: "One", query: "tag:review")
            try store.saveSmartFolder(folder)
            store.query = "title:Plan"
            store.draftSmartFolder()
            #expect(store.smartFolderDraft?.query == "tag:review title:Plan")
            #expect(store.selectedNoteID == first.id)
            #expect(FolioCommand.newSmartFolder.unavailableReason(in: store) == nil)
            store.scope = .trash
            #expect(FolioCommand.newSmartFolder.unavailableReason(in: store) != nil)
        }
    }

    @Test func duplicateNamesInvalidQueriesAndDiskFailuresNeverCommitInMemoryOrOnDisk() throws {
        try withStore { store, _, _, _, _, _ in
            let folder = SmartFolder(name: "Caf\u{e9}", query: "tag:review")
            try store.saveSmartFolder(folder)
            let original = try Data(contentsOf: store.smartFolderStorage.url)
            for invalid in [SmartFolder(name: "CAFE", query: "is:pinned"),
                            SmartFolder(name: "Invalid", query: "is:done"),
                            SmartFolder(name: "", query: "is:pinned"),
                            SmartFolder(name: String(repeating: "a", count: 101), query: "is:pinned"),
                            SmartFolder(name: "Empty", query: " ")] {
                #expect(throws: (any Error).self) { try store.saveSmartFolder(invalid) }
                #expect(store.smartFolders == [folder])
                let unchanged = try Data(contentsOf: store.smartFolderStorage.url)
                #expect(unchanged == original)
            }
            try FileManager.default.removeItem(at: store.smartFolderStorage.url)
            try FileManager.default.createDirectory(at: store.smartFolderStorage.url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) {
                try store.saveSmartFolder(SmartFolder(name: "Cannot write", query: "is:pinned"))
            }
            #expect(store.smartFolders == [folder])
            store.deleteSmartFolder(folder.id)
            #expect(store.smartFolders == [folder])
            #expect(store.errorMessage?.contains("Could not delete") == true)
        }
    }

    @Test func corruptOrFutureSmartFoldersArePreservedWithoutBlockingTheNotes() throws {
        try withStore { store, storage, _, _, _, _ in
            for invalid in [Data("broken".utf8), Data(#"{"version":2,"folders":[]}"#.utf8)] {
                try invalid.write(to: store.smartFolderStorage.url)
                let restarted = NotesStore(storage: storage)
                #expect(restarted.isLoaded)
                #expect(!restarted.smartFoldersAvailable)
                #expect(restarted.errorMessage?.contains("smart folders") == true)
                #expect(restarted.library.notes.count == 3)
                #expect(throws: (any Error).self) {
                    try restarted.saveSmartFolder(SmartFolder(name: "New", query: "is:pinned"))
                }
                let unchanged = try Data(contentsOf: store.smartFolderStorage.url)
                #expect(unchanged == invalid)
            }
            try FileManager.default.removeItem(at: store.smartFolderStorage.url)
            store.reloadSmartFolders()
            #expect(store.smartFoldersAvailable)
            #expect(store.smartFolders.isEmpty)
        }
    }

    private func withStore(_ body: (NotesStore, LibraryStorage, Notebook, Note, Note, Note) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebook = Notebook(name: "Work/Ideas")
        let personal = Notebook(name: "Personal")
        let first = Note(notebookID: notebook.id, title: "Release Plan", tags: ["review"], isPinned: true)
        let second = Note(notebookID: notebook.id, title: "Research", tags: ["ideas"])
        let other = Note(notebookID: personal.id, title: "Home", tags: ["review"])
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook, personal], notes: [first, second, other]))
        let suite = "FolioSmartFolders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(NotesStore(storage: storage, preferences: defaults), storage, notebook, first, second, other)
    }
}
