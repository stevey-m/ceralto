import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct NavigationPerformanceTests {
    @Test func repeatedNavigationReadsStayWithinInteractiveBudget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.scope = .notebook(fixture.notebooks[0].id)
        _ = fixture.store.outlineNotes
        let start = ContinuousClock.now
        var result = 0
        for _ in 0..<20 {
            for _ in 0..<120 {
                result += fixture.store.navigationFolder?.descendants.count ?? 0
                result += fixture.store.outlineNotes.count
            }
            result += fixture.store.visibleNotes.count
            result += fixture.store.tags.count
        }
        let elapsed = start.duration(to: .now)
        print("Deltos navigation: 20 warmed sidebar/list passes, 1,500 notes and 120 notebooks: \(elapsed)")
        #expect(result > 0)
        #expect(elapsed < .seconds(1), "Repeated navigation reads must not rebuild and sort the library for each row.")
    }

    @Test func cachedListsCountsLinksAndTextStayCorrectAfterEveryLibraryChange() throws {
        let fixture = try Fixture(noteCount: 30, notebookCount: 12)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let first = fixture.notebooks[0]
        let second = fixture.notebooks[1]
        let note = try #require(store.library.notes.first)
        @MainActor func check() throws {
            #expect(store.noteLinkTargets == NoteLinks.targets(in: store.library))
            let scopes: [NoteScope] = [.all, .pinned, .trash, .tag("tag-0"), .tag("changed"),
                                      .notebook(first.id), .notebook(second.id),
                                      .folder("Projects", fixture.notebooks.map(\.id))]
            for scope in scopes {
                #expect(store.noteCount(in: scope) == store.library.notes.filter { scope.includes($0) }.count)
                store.scope = scope
                for query in ["", "tag:changed", "Heading", "title:\"Synthetic note 1\"", "is:invalid"] {
                    store.query = query
                    let parsed = NoteQuery(query)
                    let names = Dictionary(uniqueKeysWithValues: store.library.notebooks.map { ($0.id, $0.name) })
                    let expected = store.library.notes.filter {
                        scope.includes($0) && parsed.matches($0, notebook: names[$0.notebookID] ?? "")
                    }.sorted {
                        if $0.isPinned != $1.isPinned { return $0.isPinned }
                        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    #expect(store.visibleNotes.map(\.id) == expected.map(\.id))
                }
            }
            for note in store.library.notes {
                let summary = store.textSummary(for: note)
                #expect(summary.excerpt == note.excerpt)
                #expect(summary.wordCount == note.wordCount)
            }
            let saved = SmartFolder(name: "Changed", query: "tag:changed")
            #expect(store.smartFolderCount(saved) == store.library.notes.filter {
                $0.deletedAt == nil && $0.tags.contains("changed")
            }.count)
        }
        try check()
        store.update(note.id) {
            $0.title = "Renamed"
            $0.body = "# New heading\n\nDifferent **words**"
            $0.tags = ["changed"]
            $0.isPinned = true
        }
        try check()
        #expect(store.moveNotes([note.id], to: second.name))
        try check()
        store.trash(note.id)
        try check()
        store.restore(note.id)
        try check()
        store.update(note.id) { $0.format = .html; $0.body = "<p>A <b>HTML</b> note</p>" }
        try check()
        #expect(store.renameNotebookBranch("Projects", to: "Archive"))
        store.scope = .notebook(first.id)
        #expect(store.navigationFolder?.id.hasPrefix("Archive/") == true)
        #expect(store.sidebarNotebooks.first?.id == "Archive")
        #expect(store.noteLinkTargets == NoteLinks.targets(in: store.library))
        store.trash(note.id)
        store.permanentlyDelete(note.id)
        #expect(store.noteCount(in: .trash) == 0)
        #expect(!store.noteLinkTargets.values.contains(note.id))
        store.query = ""
        store.scope = .all
        #expect(store.visibleNotes.count == 29)
        #expect(store.errorMessage == nil)
    }

    @Test func tabSwitchesDoNotRewriteNativeBuffersAndKeepUndoAndSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        fixture.defaults.set("Dracula", forKey: "folioTheme")
        let first = store.library.notes[0].id, second = store.library.notes[120].id
        let body = (0..<80).map { "Paragraph \($0) with **bold** and `code`." }.joined(separator: "\n\n")
        store.update(first) { $0.body = body }
        store.update(second) { $0.body = "Second document\n\n" + body }
        store.openNote(first)
        store.openNoteInNewTab(second)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(fixture.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.contentView = nil }
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if editors(in: host).count == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let a = try #require(editors(in: host).first { !$0.string.hasPrefix("Second document") })
        let b = try #require(editors(in: host).first { $0.string.hasPrefix("Second document") })
        window.makeFirstResponder(b)
        b.setSelectedRange(NSRange(location: 0, length: 6))
        let originalBuffer = NSAttributedString(attributedString: try #require(b.textStorage))
        let formatting = FormattingActions()
        formatting.editor = b
        formatting.toggle(.boldFontMask)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let counter = BufferChanges()
        for editor in [a, b] {
            NotificationCenter.default.addObserver(counter, selector: #selector(BufferChanges.changed),
                                                   name: NSTextStorage.didProcessEditingNotification,
                                                   object: try #require(editor.textStorage))
        }
        defer { NotificationCenter.default.removeObserver(counter) }
        var times: [Duration] = []
        for index in 0..<10 {
            let target = index.isMultiple(of: 2) ? a : b
            let start = ContinuousClock.now
            store.openNote(index.isMultiple(of: 2) ? first : second)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if target.isEditable { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            times.append(start.duration(to: .now))
            #expect(target.isEditable)
        }
        let slowest = try #require(times.max())
        print("Deltos native tab switching, 1,500 notes and two long Compose documents: slowest \(slowest)")
        #expect(slowest < .seconds(1))
        #expect(counter.count == 0, "Switching tabs must not recolour or replace unchanged text storage.")
        #expect(b.selectedRange() == NSRange(location: 0, length: 6))
        #expect(b.undoManager?.canUndo == true)
        b.undoManager?.undo()
        #expect(b.textStorage?.isEqual(to: originalBuffer) == true)
        let restored = try #require(store.library.notes.first { $0.id == second })
        let restoredPage = try FormattedPage(markdown: restored.body)
        let originalPage = try FormattedPage(markdown: "Second document\n\n" + body)
        #expect(restoredPage == originalPage)
        #expect(store.library.notes.first { $0.id == first }?.body == body)
    }

    private func editors(in view: NSView) -> [PageTextView] {
        if let editor = view as? PageTextView { return [editor] }
        return view.subviews.flatMap { editors(in: $0) }
    }

    @MainActor private final class BufferChanges: NSObject {
        var count = 0
        @objc func changed(_ notification: Notification) { count += 1 }
    }

    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeltosNavigationPerformance-\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: NotesStore
        let notebooks: [Notebook]

        init(noteCount: Int = 1_500, notebookCount: Int = 120) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let notebooks = (0..<notebookCount).map { Notebook(name: "Projects/Group \($0 / 10)/Notebook \($0)") }
            self.notebooks = notebooks
            let notes = (0..<noteCount).map { index in
                Note(notebookID: notebooks[index % notebooks.count].id, title: "Synthetic note \(index)",
                     body: "# Heading \(index)\n\nSome **formatted** text and a [[Synthetic note 1]] link.\n\n- A point\n- Another point",
                     tags: ["tag-\(index % 12)"], format: .formatted)
            }
            let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
            try storage.save(Library(notebooks: notebooks, notes: notes))
            store = NotesStore(storage: storage, preferences: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove navigation fixture: \(error.localizedDescription)") }
        }
    }
}
