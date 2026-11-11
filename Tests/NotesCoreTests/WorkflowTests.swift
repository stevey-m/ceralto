import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

struct NoteTaskTests {
    @Test func indexesRealTasksIncludingNestedOrderedAndQuotedListsButNotCodeOrHtml() throws {
        let note = Note(notebookID: UUID(), body: """
        # Tasks
        - [ ] First
        - [x] Done
          - [X] Nested
        1. [ ] Numbered
        > - [ ] Quoted

        - Parent
        \t- [ ] Tab nested

        ```markdown
        - [ ] Not a task
        ```

            - [ ] Indented code

        Text [ ] is not a task.
        \\- [ ] Escaped bullet
        - \\[ ] Escaped checkbox

        <div>
        - [ ] HTML block
        </div>
        """)
        let tasks = try NoteTasks.find(in: note)
        #expect(tasks.map(\.title) == ["First", "Done", "Nested", "Numbered", "Quoted", "Tab nested"])
        #expect(tasks.map(\.isComplete) == [false, true, true, false, false, false])
        #expect(Set(tasks.map(\.id)).count == tasks.count)
        #expect(tasks.first?.lineNumber == 2)
    }

    @Test func completionOnlyChangesOneMarkerAndPreservesUnicodeCrLfAndOtherTasks() throws {
        let body = "- Parent\r\n\t- [ ] Caf\u{e9} \u{1f4da}\r\n- [X] Done\r\n"
        let note = Note(notebookID: UUID(), body: body)
        let tasks = try NoteTasks.find(in: note)
        #expect(tasks.count == 2)
        let first = try #require(tasks.first)
        let checked = try NoteTasks.setting(first, complete: true, in: note)
        #expect(checked == body.replacingOccurrences(of: "[ ]", with: "[x]"))
        var updated = note
        updated.body = checked
        let refreshed = try NoteTasks.find(in: updated)
        let refreshedTask = try #require(refreshed.first)
        let undone = try NoteTasks.setting(refreshedTask, complete: false, in: updated)
        #expect(undone == body)
    }

    @Test func staleMovedDeletedAndNewlyFencedTasksCannotChangeAnotherLine() throws {
        let note = Note(notebookID: UUID(), body: "- [ ] Keep me")
        let tasks = try NoteTasks.find(in: note)
        let task = try #require(tasks.first)
        var changed = note
        changed.body = "- [ ] Different"
        #expect(throws: (any Error).self) { try NoteTasks.setting(task, complete: true, in: changed) }
        changed.body = "```\n- [ ] Keep me\n```"
        #expect(throws: (any Error).self) { try NoteTasks.setting(task, complete: true, in: changed) }
        changed = note
        changed.deletedAt = Date()
        #expect(throws: (any Error).self) { try NoteTasks.setting(task, complete: true, in: changed) }
        let other = Note(notebookID: note.notebookID, body: note.body)
        #expect(throws: (any Error).self) { try NoteTasks.setting(task, complete: true, in: other) }
    }

    @Test func libraryTasksExcludeTrashAndHtmlAndKeepIdenticalTaskLinesDistinct() throws {
        let notebook = Notebook(name: "Work")
        let note = Note(notebookID: notebook.id, body: "- [ ] Same\n- [ ] Same")
        let trash = Note(notebookID: notebook.id, body: "- [ ] Deleted", deletedAt: Date())
        let html = Note(notebookID: notebook.id, body: "<p>- [ ] HTML</p>", format: .html)
        let tasks = try NoteTasks.find(in: Library(notebooks: [notebook], notes: [note, trash, html]))
        #expect(tasks.count == 2)
        #expect(tasks[0].id != tasks[1].id)
        let changed = try NoteTasks.setting(tasks[1], complete: true, in: note)
        #expect(changed == "- [ ] Same\n- [x] Same")
    }
}

@MainActor
struct DailyWorkflowTests {
    @Test func todayReopensTheSameNoteWithoutOverwritingEditsAndTomorrowCreatesAnother() throws {
        try withStore { store, storage, _ in
            let date = Date()
            let originalCount = store.library.notes.count
            try store.openDailyNote(on: date)
            let id = try #require(store.selectedNoteID)
            #expect(store.selectedNote?.contentFormat == .markdown)
            #expect(store.library.notebooks.filter { $0.name == "Journal" }.count == 1)
            #expect(store.selectedNote?.title == TemplateChoice.builtIn[0].template.render("{{date}}", date: date))
            store.update(id) { $0.body += "My own words\n- [ ] Read the chapter" }
            try store.openDailyNote(on: date)
            #expect(store.selectedNoteID == id)
            #expect(store.selectedNote?.body.contains("My own words") == true)
            #expect(store.library.notes.count == originalCount + 1)
            #expect(store.workspace.tabs.filter { $0 == id }.count == 1)
            let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: date))
            try store.openDailyNote(on: tomorrow)
            #expect(store.selectedNoteID != id)
            #expect(store.library.notes.count == originalCount + 2)
            let saved = try storage.load()
            #expect(saved?.notes.first { $0.id == id }?.body.contains("My own words") == true)
            let restarted = NotesStore(storage: storage)
            try restarted.openDailyNote(on: date)
            #expect(restarted.selectedNoteID == id)
        }
    }

    @Test func dailyNotebookAndTemplateAreConfigurableButExistingNotesAreNeverReplaced() throws {
        try withStore { store, _, defaults in
            defaults.set("Personal/Journal", forKey: "dailyNotebook")
            defaults.set(TemplateChoice.builtIn[2].id, forKey: "dailyTemplate")
            try store.openDailyNote()
            let note = try #require(store.selectedNote)
            #expect(note.body.hasPrefix("# Project"))
            #expect(note.tags.contains("daily"))
            #expect(store.library.notebooks.first { $0.id == note.notebookID }?.name == "Personal/Journal")
            defaults.set("missing/template", forKey: "dailyTemplate")
            try store.openDailyNote()
            #expect(store.selectedNoteID == note.id)
            let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Date()))
            let before = store.library
            #expect(throws: (any Error).self) { try store.openDailyNote(on: tomorrow) }
            #expect(store.library == before)
            defaults.set(" ", forKey: "dailyNotebook")
            #expect(throws: (any Error).self) { try store.openDailyNote() }
        }
    }

    @Test func trashedDailyNoteMustBeRestoredRatherThanRecreatedOrSilentlyRestored() throws {
        try withStore { store, _, _ in
            try store.openDailyNote()
            let id = try #require(store.selectedNoteID)
            store.trash(id)
            let count = store.library.notes.count
            #expect(throws: (any Error).self) { try store.openDailyNote() }
            #expect(store.library.notes.count == count)
            #expect(store.library.notes.first { $0.id == id }?.deletedAt != nil)
            store.restore(id)
            try store.openDailyNote()
            #expect(store.selectedNoteID == id)
        }
    }

    @Test func failedDailyAndTemplateSavesDoNotCreatePartialNotesOrNotebooks() throws {
        try withStore { store, storage, _ in
            let before = store.library
            let selection = store.selectedNoteID
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.openDailyNote() }
            #expect(store.library == before)
            #expect(store.selectedNoteID == selection)
            #expect(!store.createFromTemplate(TemplateChoice.builtIn[1].template))
            #expect(store.library == before)
            #expect(store.errorMessage?.contains("template") == true)
        }
    }

    @Test func builtInAndCommunityTemplatesCreatePortableSourceNotesAndTasksPersistInOriginal() throws {
        try withStore { store, storage, _ in
            let folder = store.extensionsDirectory.appendingPathComponent("community")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"id":"test.community","name":"Community","apiVersion":1,"templates":[{"id":"review","name":"Review","title":"Review {{date}}","body":"- [ ] Read the chapter","tags":["review"]}]}"#.utf8)
                .write(to: folder.appendingPathComponent("extension.json"))
            store.reloadExtensions()
            #expect(store.templateChoices.count == 4)
            let template = try #require(store.templateChoices.first { $0.packID == "test.community" })
            #expect(store.createFromTemplate(template.template))
            let note = try #require(store.selectedNote)
            #expect(note.contentFormat == .markdown)
            #expect(note.tags == ["review"])
            let tasks = try NoteTasks.find(in: store.library)
            let task = try #require(tasks.first { $0.noteID == note.id })
            let selected = store.selectedNoteID
            store.setTask(task, complete: true)
            #expect(store.selectedNoteID == selected)
            #expect(store.library.notes.first { $0.id == note.id }?.body == "- [x] Read the chapter")
            #expect(store.library.notes.first { $0.id == note.id }?.history?.last?.body == note.body)
            let saved = try storage.load()
            #expect(saved?.notes.first { $0.id == note.id }?.body == "- [x] Read the chapter")
            store.setTask(task, complete: false)
            #expect(store.errorMessage?.contains("changed") == true)
        }
    }

    @Test func duplicateNotebookPathsReuseTheExistingDailyNoteAndReadOnlyReadersCannotCreateOrToggle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Notebook(name: "Journal"), second = Notebook(name: "Journal")
        let date = Date()
        let note = Note(notebookID: second.id, title: TemplateChoice.daily.template.render("{{date}}", date: date),
                        body: "- [ ] Read the chapter")
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [first, second], notes: [note]))
        let suite = "FolioDailyDuplicates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotesStore(storage: storage, preferences: defaults)
        try store.openDailyNote(on: date)
        #expect(store.selectedNoteID == note.id)
        #expect(store.library.notes.count == 1)
        let reader = NotesStore(storage: storage, readOnly: true, preferences: defaults)
        let before = reader.library
        #expect(throws: (any Error).self) { try reader.openDailyNote(on: date) }
        #expect(!reader.createFromTemplate(TemplateChoice.daily.template))
        let tasks = try NoteTasks.find(in: note)
        let task = try #require(tasks.first)
        reader.setTask(task, complete: true)
        #expect(reader.library == before)
        #expect(reader.errorMessage != nil)
    }

    @Test func taskSaveFailureKeepsTheChangeVisibleAndRetryPersistsIt() throws {
        try withStore { store, storage, _ in
            #expect(store.createFromTemplate(TemplateChoice.builtIn[2].template))
            let note = try #require(store.selectedNote)
            let tasks = try NoteTasks.find(in: note)
            let task = try #require(tasks.first)
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            store.setTask(task, complete: true)
            #expect(store.hasUnsavedChanges)
            #expect(store.errorMessage?.contains("still in memory") == true)
            #expect(store.selectedNote?.body.contains("- [x]") == true)
            try FileManager.default.removeItem(at: storage.url)
            store.save()
            #expect(!store.hasUnsavedChanges)
            let saved = try storage.load()
            #expect(saved?.notes.first { $0.id == note.id }?.body.contains("- [x]") == true)
        }
    }

    private func withStore(_ action: (NotesStore, LibraryStorage, UserDefaults) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioDaily-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try action(NotesStore(storage: storage, preferences: defaults), storage, defaults)
    }
}

private struct ShortcutFixture: View {
    @ObservedObject var store: NotesStore
    let onPress: () -> Void
    var body: some View {
        Button("Action", action: onPress).keyboardShortcut(store.shortcut(.newNote).keyboardShortcut)
    }
}

@MainActor
struct KeyboardShortcutTests {
    @Test func nativeShortcutChangesRemoveTheOldKeyAndUnassignmentDisablesIt() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioNativeKeys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: defaults)
        var hits = 0
        let host = NSHostingView(rootView: ShortcutFixture(store: store, onPress: { hits += 1 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.makeFirstResponder(host)
        func key(_ character: String, flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: code))
        }
        func awaitRouting(_ event: NSEvent, handled expected: Bool) async throws {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                let before = hits
                let handled = window.performKeyEquivalent(with: event)
                #expect(hits == before + (handled ? 1 : 0))
                if handled == expected { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("The native shortcut did not reach the expected routing state: \(expected).")
        }
        let original = try key("n", flags: .command, code: 45)
        try await awaitRouting(original, handled: true)
        #expect(hits == 1)
        var bindings = store.shortcutBindings
        bindings[ShortcutAction.newNote.rawValue] = ShortcutBinding(key: "d", modifiers: 2)
        try store.saveShortcuts(bindings)
        let custom = try key("d", flags: [.command, .option], code: 2)
        try await awaitRouting(custom, handled: true)
        #expect(!window.performKeyEquivalent(with: original))
        #expect(hits == 2)
        bindings[ShortcutAction.newNote.rawValue] = ShortcutBinding(key: "")
        try store.saveShortcuts(bindings)
        try await awaitRouting(custom, handled: false)
        let disabledHits = hits
        #expect(!window.performKeyEquivalent(with: custom))
        #expect(!window.performKeyEquivalent(with: original))
        #expect(hits == disabledHits)
    }

    @Test func defaultAssignmentsAreUniqueAndReservedOrInvalidCombinationsAreRejected() throws {
        let defaults = ShortcutConfiguration.defaults
        try ShortcutConfiguration.validate(defaults)
        for invalid in [ShortcutBinding(key: "q"), ShortcutBinding(key: "f"), ShortcutBinding(key: "ab"),
                        ShortcutBinding(key: "n", modifiers: 8), ShortcutBinding(key: "k"),
                        ShortcutBinding(key: "-"), ShortcutBinding(key: "=", modifiers: 1)] {
            var bindings = defaults
            bindings[ShortcutAction.today.rawValue] = invalid
            #expect(throws: (any Error).self) { try ShortcutConfiguration.validate(bindings) }
        }

        var disabled = defaults
        disabled[ShortcutAction.today.rawValue] = ShortcutBinding(key: "")
        disabled[ShortcutAction.tasks.rawValue] = ShortcutBinding(key: "")
        try ShortcutConfiguration.validate(disabled)
        #expect(disabled[ShortcutAction.today.rawValue]?.keyboardShortcut == nil)
    }

    @Test func customAssignmentsPersistAndUpdateThePaletteWithoutKeepingOldBindings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioKeys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage, preferences: defaults)
        var bindings = store.shortcutBindings
        bindings[ShortcutAction.today.rawValue] = ShortcutBinding(key: "d", modifiers: 2)
        try store.saveShortcuts(bindings)
        #expect(store.shortcut(.today).label == "⌥⌘D")
        #expect(FolioCommand.today.shortcut(in: store) == "⌥⌘D")
        let restarted = NotesStore(storage: storage, preferences: defaults)
        #expect(restarted.shortcutBindings == bindings)
        var collision = bindings
        collision[ShortcutAction.tasks.rawValue] = bindings[ShortcutAction.today.rawValue]
        #expect(throws: (any Error).self) { try store.saveShortcuts(collision) }
        #expect(store.shortcutBindings == bindings)
        store.resetShortcuts()
        #expect(store.shortcutBindings == ShortcutConfiguration.defaults)
        #expect(defaults.data(forKey: "keyboardShortcuts") == nil)
    }

    @Test func malformedAndFuturePreferencesArePreservedUntilExplicitReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioBadKeys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for data in [Data("broken".utf8), Data(#"{"version":2,"bindings":{}}"#.utf8)] {
            defaults.set(data, forKey: "keyboardShortcuts")
            let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: defaults)
            #expect(store.isLoaded)
            #expect(!store.shortcutsAvailable)
            #expect(store.errorMessage?.contains("shortcuts") == true)
            #expect(store.shortcutBindings == ShortcutConfiguration.defaults)
            #expect(defaults.data(forKey: "keyboardShortcuts") == data)
            #expect(throws: (any Error).self) { try store.saveShortcuts(ShortcutConfiguration.defaults) }
            store.resetShortcuts()
            #expect(store.shortcutsAvailable)
            #expect(defaults.data(forKey: "keyboardShortcuts") == nil)
        }
    }
}
