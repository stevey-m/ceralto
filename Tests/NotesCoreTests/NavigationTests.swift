import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

struct DocumentWorkspaceTests {
    @Test func navigationBranchesClosesReopensAndPrunesWithoutDuplicates() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var workspace = DocumentWorkspace()
        workspace.select(a)
        workspace.select(b)
        workspace.select(b)
        #expect(workspace.tabs == [a, b])
        #expect(workspace.goBack() == a)
        #expect(workspace.canGoForward)
        workspace.select(c, replacingCurrent: true)
        #expect(workspace.tabs == [c, b])
        #expect(!workspace.canGoForward)
        workspace.close(c)
        #expect(workspace.activeID == b)
        workspace.close(b)
        #expect(workspace.activeID == nil)
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.goBack() == c)
        #expect(workspace.tabs == [c])
        workspace.retainNotes([a, b])
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeID == nil)
        try workspace.validate()
        let restored = try JSONDecoder().decode(DocumentWorkspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored == workspace)
    }

    @Test func historyIsBoundedAndInvalidPersistedStateIsRejected() throws {
        var workspace = DocumentWorkspace()
        for _ in 0..<150 { workspace.select(UUID(), replacingCurrent: true) }
        #expect(workspace.tabs.count == 1)
        var count = 0
        while workspace.goBack() != nil { count += 1 }
        #expect(count == 99)
        try workspace.validate()
        let malformed = Data(#"{"tabs":[],"history":[],"position":40}"#.utf8)
        let bad = try JSONDecoder().decode(DocumentWorkspace.self, from: malformed)
        #expect(throws: LibraryError.self) { try bad.validate() }
    }
}

@Suite(.serialized)
@MainActor
struct NavigationTests {
    @Test func tabsRestoreAcrossLaunchesAndClosingNeverDeletesNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage)
        let original = try #require(store.selectedNoteID)
        store.createNote()
        let second = try #require(store.selectedNoteID)
        store.update(second) { $0.body = "Keep this text" }
        store.openNote(original)
        #expect(store.workspace.tabs == [original, second])
        let restarted = NotesStore(storage: storage)
        #expect(restarted.errorMessage == nil)
        #expect(restarted.selectedNoteID == original)
        #expect(restarted.workspace.tabs == [original, second])
        restarted.navigateBack()
        #expect(restarted.selectedNoteID == second)
        restarted.closeTab(second)
        #expect(restarted.selectedNoteID == original)
        #expect(restarted.library.notes.first { $0.id == second }?.body == "Keep this text")
        restarted.scope = .trash
        restarted.trash(second)
        restarted.permanentlyDelete(second)
        #expect(!restarted.workspace.tabs.contains(second))
        let final = NotesStore(storage: storage)
        #expect(!final.workspace.tabs.contains(second))
    }

    @Test func ordinarySelectionReusesATabAndExplicitOpenKeepsBoth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Ideas")
        let first = Note(notebookID: notebook.id, title: "First")
        let second = Note(notebookID: notebook.id, title: "Second")
        try storage.save(Library(notebooks: [notebook], notes: [first, second]))
        let store = NotesStore(storage: storage)
        store.openNote(first.id)
        store.selectedNoteID = second.id
        #expect(store.workspace.tabs == [second.id])
        store.openNoteInNewTab(first.id)
        #expect(store.workspace.tabs == [second.id, first.id])
        store.closeTab(second.id)
        #expect(store.selectedNoteID == first.id)
        store.closeTab(first.id)
        #expect(store.selectedNoteID == nil)
        let restarted = NotesStore(storage: storage)
        #expect(restarted.workspace.tabs.isEmpty)
        #expect(restarted.selectedNoteID == nil)
        #expect(restarted.library.notes.count == 2)
    }

    @Test func corruptWorkspaceDoesNotBlockOrModifyLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(.starter())
        let before = try Data(contentsOf: storage.url)
        try Data("invalid workspace".utf8).write(to: directory.appendingPathComponent("workspace.json"))
        let store = NotesStore(storage: storage)
        #expect(store.isLoaded)
        #expect(store.errorMessage?.contains("tabs") == true)
        let after = try Data(contentsOf: storage.url)
        #expect(before == after)
    }

    @Test func openComposeTabsKeepNativeSelectionUndoAndDoNotEditTheHiddenNote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Personal")
        let first = Note(notebookID: notebook.id, title: "First", body: "First page", format: .formatted)
        let second = Note(notebookID: notebook.id, title: "Second", body: "Second page", format: .formatted)
        try storage.save(Library(notebooks: [notebook], notes: [first, second]))
        let store = NotesStore(storage: storage)
        store.openNote(first.id)
        store.openNoteInNewTab(second.id)
        store.openNote(first.id)
        let host = NSHostingView(rootView: ContentView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [PageTextView] {
            if let editor = view as? PageTextView { return [editor] }
            return view.subviews.flatMap(editors)
        }
        let firstEditor = try #require(editors(host).first { $0.string == "First page" })
        let secondEditor = try #require(editors(host).first { $0.string == "Second page" })
        func awaitActivation(_ active: NSTextView, inactive: NSTextView) async throws {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if active.isEditable && !inactive.isEditable { return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await awaitActivation(firstEditor, inactive: secondEditor)
        #expect(firstEditor.isEditable)
        #expect(!secondEditor.isEditable)
        window.makeFirstResponder(firstEditor)
        firstEditor.setSelectedRange(NSRange(location: 0, length: 5))
        let actions = FormattingActions()
        actions.editor = firstEditor
        actions.toggle(.boldFontMask)
        try await Task.sleep(for: .milliseconds(50))
        let undo = try #require(firstEditor.undoManager)
        #expect(undo.canUndo)
        store.openNote(second.id)
        try await awaitActivation(secondEditor, inactive: firstEditor)
        host.layoutSubtreeIfNeeded()
        #expect(!firstEditor.isEditable)
        #expect(secondEditor.isEditable)
        #expect(firstEditor.undoManager !== secondEditor.undoManager)
        #expect(store.library.notes.first { $0.id == second.id }?.body == "Second page")
        store.openNote(first.id)
        try await awaitActivation(firstEditor, inactive: secondEditor)
        host.layoutSubtreeIfNeeded()
        #expect(editors(host).contains { $0 === firstEditor })
        #expect(firstEditor.selectedRange() == NSRange(location: 0, length: 5))
        store.showReference(second.id)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(editors(host).contains { $0 === firstEditor })
        #expect(firstEditor.frame.width >= 200)
        #expect(firstEditor.undoManager?.canUndo == true)
        store.showReference(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(editors(host).contains { $0 === firstEditor })
        undo.undo()
        #expect(store.library.notes.first { $0.id == first.id }?.body == "First page")
        #expect(store.library.notes.first { $0.id == second.id }?.body == "Second page")
    }

    @Test func commandRegistryFiltersAndRunsTheSameActionsAsMenus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioCommands-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: preferences)
        #expect(FolioCommand.matching("complete backup") == [.backup, .encryptedBackup])
        #expect(FolioCommand.matching("no such command").isEmpty)
        #expect(FolioCommand.sync.unavailableReason(in: store) != nil)
        #expect(FolioCommand.back.unavailableReason(in: store) != nil)
        store.perform(.newNote)
        #expect(store.workspace.tabs.count == 2)
        #expect(FolioCommand.back.unavailableReason(in: store) == nil)
        store.perform(.find)
        #expect(store.showingFinder)
        store.perform(.toggleFolders)
        #expect(!preferences.bool(forKey: "showNotebookPane"))
        store.perform(.focus)
        #expect(!preferences.bool(forKey: "showNoteListPane"))
        store.perform(.focus)
        #expect(preferences.bool(forKey: "showNotebookPane"))
        #expect(preferences.bool(forKey: "showNoteListPane"))
        store.perform(.closeTab)
        #expect(store.workspace.tabs.count == 1)
        #expect(store.library.notes.count == 2)
    }

    @Test func sourceTabsDoNotShareUndoManagers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioSourceTabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Write", forKey: "readingEditorMode")
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Personal")
        let first = Note(notebookID: notebook.id, title: "First", body: "First source")
        let second = Note(notebookID: notebook.id, title: "Second", body: "Second source")
        try storage.save(Library(notebooks: [notebook], notes: [first, second]))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.openNote(first.id)
        store.openNoteInNewTab(second.id)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap(editors)
        }
        let a = try #require(editors(host).first { $0.string == first.body })
        let b = try #require(editors(host).first { $0.string == second.body })
        let firstUndo = try #require(a.undoManager)
        let secondUndo = try #require(b.undoManager)
        #expect(firstUndo !== secondUndo)
        #expect(!a.isEditable)
        #expect(b.isEditable)
        #expect(b.frame.width >= 300)
        #expect(b.frame.height > 100)
        window.makeFirstResponder(b)
        b.setSelectedRange(NSRange(location: b.string.utf16.count, length: 0))
        b.insertText(" edited", replacementRange: b.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.selectedNote?.body == "Second source edited")
        #expect(secondUndo.canUndo)
        store.openNote(first.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.isEditable)
        #expect(!b.isEditable)
        #expect(store.selectedNote?.body == "First source")
        window.makeFirstResponder(a)
        a.setSelectedRange(NSRange(location: a.string.utf16.count, length: 0))
        a.insertText(" changed", replacementRange: a.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        #expect(firstUndo.canUndo)
        firstUndo.undo()
        #expect(a.string == "First source")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.selectedNote?.body == "First source")
        #expect(store.library.notes.first { $0.id == second.id }?.body == "Second source edited")
        firstUndo.redo()
        #expect(a.string == "First source changed")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.selectedNote?.body == "First source changed")
        let saved = try storage.load()
        #expect(saved?.notes.first { $0.id == first.id }?.body == "First source changed")
    }

    @Test func referenceIsIndependentRestoredAndRemovedWithDeletedNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage)
        let reference = try #require(store.selectedNoteID)
        store.perform(.reference)
        store.createNote()
        let active = try #require(store.selectedNoteID)
        #expect(store.referenceNote?.id == reference)
        #expect(store.selectedNoteID == active)
        let restarted = NotesStore(storage: storage)
        #expect(restarted.referenceNote?.id == reference)
        #expect(restarted.selectedNoteID == active)
        restarted.trash(reference)
        restarted.permanentlyDelete(reference)
        #expect(restarted.referenceNote == nil)
        #expect(restarted.selectedNoteID == active)
    }
}
