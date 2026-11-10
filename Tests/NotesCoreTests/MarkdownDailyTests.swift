import AppKit
import Foundation
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

struct MarkdownSearchTests {
    @Test func searchesPathsAndContentsAcrossNestedNotesWithoutChangingFiles() throws {
        try fixture { folder in
            try folder.createDirectory(at: "Research")
            try folder.createNote(at: "Research/Café.markdown", text: "# Field notes\n\nA northern LIGHTS expedition.\nSecond line.")
            try folder.createNote(at: "Other.md", text: "Northern roads")
            let before = try Data(contentsOf: folder.url(for: "Research/Café.markdown"))
            let report = try folder.search("cafe lights")
            #expect(report.matches.map(\.path) == ["Research/Café.markdown"])
            #expect(report.matches[0].excerpt.contains("LIGHTS expedition"))
            #expect(!report.matches[0].excerpt.contains("\n"))
            #expect(report.unreadable.isEmpty)
            #expect(!report.truncated)
            let after = try Data(contentsOf: folder.url(for: "Research/Café.markdown"))
            #expect(before == after)
            #expect(try folder.search(" \n ").matches.isEmpty)
            #expect(try folder.search("missing").matches.isEmpty)
        }
    }

    @Test func unreadableNotesAreReportedAndHiddenSymlinkAndNonMarkdownFilesAreExcluded() throws {
        try fixture { folder in
            try folder.createNote(at: "Good.md", text: "Find me")
            try Data([0xff, 0xfe, 0x80]).write(to: folder.root.appendingPathComponent("Bad.md"))
            try Data("Find me".utf8).write(to: folder.root.appendingPathComponent(".hidden.md"))
            try Data("Find me".utf8).write(to: folder.root.appendingPathComponent("Document.txt"))
            try FileManager.default.createSymbolicLink(at: folder.root.appendingPathComponent("Linked.md"),
                                                       withDestinationURL: folder.root.appendingPathComponent("Good.md"))
            let report = try folder.search("find")
            #expect(report.matches.map(\.path) == ["Good.md"])
            #expect(report.unreadable.count == 1)
            #expect(report.unreadable[0].hasPrefix("Bad.md:"))
            // A path match must not pretend an unreadable note's body was searched successfully.
            let invalid = try folder.search("Bad")
            #expect(invalid.matches.isEmpty)
            #expect(invalid.unreadable.count == 1)
        }
    }

    @Test func resultLimitsAreExactAndSnippetsAreBoundedForUnicodeNotes() throws {
        try fixture { folder in
            for index in 0..<4 {
                try folder.createNote(at: "Note\(index).md", text: String(repeating: "🌍", count: 300) + " match " + String(repeating: "é", count: 300))
            }
            let truncated = try folder.search("match", limit: 3)
            #expect(truncated.matches.count == 3)
            #expect(truncated.truncated)
            #expect(truncated.matches.allSatisfy { $0.excerpt.count <= 180 && $0.excerpt.contains("match") })
            let complete = try folder.search("match", limit: 4)
            #expect(complete.matches.count == 4)
            #expect(!complete.truncated)
            #expect(throws: (any Error).self) { try folder.search("match", limit: 0) }
        }
    }

    @Test func canceledSearchDoesNotReturnStaleResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try LiveMarkdownFolder(root: root)
        try folder.createNote(at: "Note.md", text: "match")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try folder.search("match")
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must not return a search report.")
        } catch is CancellationError {}
    }

    @Test func defaultSearchLimitIsTwoHundredWithAnExplicitTruncationFlag() throws {
        try fixture { folder in
            for index in 0..<201 { try folder.createNote(at: "Note\(index).md", text: "Matching body") }
            let report = try folder.search("matching")
            #expect(report.matches.count == 200)
            #expect(report.truncated)
            #expect(report.unreadable.isEmpty)
        }
    }

    private func fixture(_ action: (LiveMarkdownFolder) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(LiveMarkdownFolder(root: root))
    }
}

@Suite(.serialized)
@MainActor
struct MarkdownDailyTests {
    @Test func remembersTheFolderAndSelectedNoteWithoutImportingOrWritingSidecars() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Work/Research.md")
            let before = try folder.entries()
            let second = LiveMarkdownStore(stateDirectory: directory)
            #expect(second.hasRememberedFolder)
            second.reopenLast(avoiding: library)
            #expect(second.folder?.root == folder.root)
            #expect(second.selectedPath == "Work/Research.md")
            #expect(second.text == "Northern lights research")
            #expect(!second.dirty)
            #expect(try folder.entries() == before)
            let disk = try Data(contentsOf: library)
            #expect(disk == Data("Normal library remains untouched".utf8))
            second.forgetFolder()
            let third = LiveMarkdownStore(stateDirectory: directory)
            #expect(!third.hasRememberedFolder)
            #expect(second.folder?.root == folder.root)
        }
    }

    @Test func restoresLatestKeystrokesWithoutWritingTheOriginalAndSaveClearsRecovery() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Idea.md")
            first.text = "Draft one"
            first.text = "Latest unsaved words 🌍"
            #expect(first.recoveryIssue == nil)
            #expect(try folder.read("Idea.md").text == "Original idea")
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.text == "Latest unsaved words 🌍")
            #expect(second.dirty)
            #expect(!second.conflict)
            #expect(second.message.contains("Recovered"))
            #expect(second.save())
            #expect(second.recoverable.isEmpty)
            #expect(try folder.read("Idea.md").text == "Latest unsaved words 🌍")
            let third = LiveMarkdownStore(stateDirectory: directory)
            third.reopenLast(avoiding: library)
            #expect(third.text == "Latest unsaved words 🌍")
            #expect(!third.dirty)
            #expect(third.recoverable.isEmpty)
        }
    }

    @Test func crashRecoveryPreservesExternalEditsAndCanSaveASeparateCopy() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Idea.md")
            first.text = "Recovered draft"
            try Data("External changes".utf8).write(to: folder.url(for: "Idea.md"), options: .atomic)
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.text == "Recovered draft")
            #expect(second.conflict)
            #expect(!second.save())
            #expect(try folder.read("Idea.md").text == "External changes")
            second.create(path: "Recovered.md", directory: false, copyDraft: true)
            #expect(second.selectedPath == "Recovered.md")
            #expect(second.recoverable.isEmpty)
            #expect(try folder.read("Recovered.md").text == "Recovered draft")
            second.select("Idea.md")
            #expect(second.text == "External changes")
        }
    }

    @Test func bookmarkedFolderRenameCarriesItsDraftAndSelectionToTheNewLocation() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Work/Research.md")
            first.text = "Draft before folder rename"
            let destination = root.appendingPathComponent("Renamed Markdown")
            try FileManager.default.moveItem(at: folder.root, to: destination)
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.folder?.root == destination.resolvingSymlinksInPath())
            #expect(second.selectedPath == "Work/Research.md")
            #expect(second.text == "Draft before folder rename")
            #expect(second.dirty)
            #expect(second.recoveryIssue == nil)
            #expect(try second.recovery.drafts(for: folder.root).isEmpty)
            #expect(second.recoverable.count == 1)
            #expect(second.save())
            let moved = try LiveMarkdownFolder(root: destination)
            #expect(try moved.read("Work/Research.md").text == "Draft before folder rename")
        }
    }

    @Test func savedDraftLeftByInterruptedCleanupIsRecognizedAndNotRestoredAsADirtyEdit() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Idea.md")
            first.text = "Already saved"
            try Data("Already saved".utf8).write(to: folder.url(for: "Idea.md"), options: .atomic)
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.text == "Already saved")
            #expect(!second.dirty)
            #expect(!second.conflict)
            #expect(second.recoverable.isEmpty)
        }
    }

    @Test func missingOrRenamedFilesRetainRecoveredDraftsAndNeverGetRecreatedOnSave() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Idea.md")
            first.text = "Keep this after rename"
            try folder.move("Idea.md", to: "Renamed.md")
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.selectedPath == "Idea.md")
            #expect(second.text == "Keep this after rename")
            #expect(second.conflict)
            #expect(!second.save())
            #expect(!FileManager.default.fileExists(atPath: folder.root.appendingPathComponent("Idea.md").path))
            #expect(second.resolveDraft(.cancel) == false)
            #expect(second.resolveDraft(.discard))
            #expect(second.recoverable.isEmpty)
            #expect(!second.dirty)
            #expect(try folder.read("Renamed.md").text == "Original idea")
        }
    }

    @Test func unselectedDraftsRemainDiscoverableAndForgetDoesNotDeleteThem() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let model = LiveMarkdownStore(stateDirectory: directory)
            try model.open(folder.root, avoiding: library)
            let source = try folder.read("Work/Research.md")
            let draft = MarkdownDraft(root: folder.root, path: "Work/Research.md", original: source, text: "Recovered research")
            try model.recovery.saveDraft(draft)
            model.select("Idea.md")
            model.forgetFolder()
            let second = LiveMarkdownStore(stateDirectory: directory)
            try second.open(folder.root, avoiding: library)
            #expect(second.recoverable.count == 1)
            second.recover(try #require(second.recoverable.first))
            #expect(second.text == "Recovered research")
            #expect(second.dirty)
            #expect(second.resolveDraft(.discard))
            second.select("Idea.md")
            second.move("Work", to: "Research")
            #expect(try folder.read("Research/Research.md").text == "Northern lights research")
        }
    }

    @Test func corruptSessionIsPreservedUntilExplicitForgetAndMissingFolderCanReconnect() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let session = directory.appendingPathComponent("session.json")
            let bytes = Data("corrupt session".utf8)
            try bytes.write(to: session)
            let model = LiveMarkdownStore(stateDirectory: directory)
            #expect(model.recoveryIssue != nil)
            #expect(throws: (any Error).self) { try model.open(folder.root, avoiding: library) }
            #expect(try Data(contentsOf: session) == bytes)
            model.forgetFolder()
            try model.open(folder.root, avoiding: library)
            model.select("Idea.md")
            model.text = "Safe local draft"
            try FileManager.default.removeItem(at: folder.root)
            let second = LiveMarkdownStore(stateDirectory: directory)
            second.reopenLast(avoiding: library)
            #expect(second.folder == nil)
            #expect(second.message.contains("could not be reopened"))
            #expect(try second.recovery.drafts(for: folder.root).first?.text == "Safe local draft")
            try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: false)
            try folder.createNote(at: "Idea.md", text: "Replacement file")
            try second.open(folder.root, avoiding: library)
            second.select("Idea.md")
            #expect(second.text == "Safe local draft")
            #expect(second.conflict)
        }
    }

    @Test func corruptDraftAndFailedWritesAreExplicitAndDoNotDeleteExistingRecovery() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let model = LiveMarkdownStore(stateDirectory: directory)
            try model.open(folder.root, avoiding: library)
            model.select("Idea.md")
            model.text = "Protected version"
            let draft = try #require(model.recoverable.first)
            let file = directory.appendingPathComponent("Drafts/\(draft.id).json")
            let bytes = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            model.text = "Newest version only in memory"
            #expect(model.recoveryIssue?.contains("only in memory") == true)
            #expect(model.text == "Newest version only in memory")
            #expect(!model.resolveDraft(.discard))
            #expect(model.dirty)
            try FileManager.default.removeItem(at: file)
            try bytes.write(to: file)
            #expect(try model.recovery.drafts(for: folder.root).first?.text == "Protected version")
            try Data("corrupt draft".utf8).write(to: file)
            let preserved = try Data(contentsOf: file)
            let restarted = LiveMarkdownStore(stateDirectory: directory)
            restarted.reopenLast(avoiding: library)
            #expect(restarted.folder == nil)
            #expect(restarted.message.contains("could not be reopened"))
            #expect(try Data(contentsOf: file) == preserved)
        }
    }

    @Test func successfulFileSaveReportsRecoveryCleanupFailureWithoutPretendingTheWriteWasBlocked() throws {
        try fixture { root, folder, library in
            let directory = root.appendingPathComponent("Recovery")
            let model = LiveMarkdownStore(stateDirectory: directory)
            try model.open(folder.root, avoiding: library)
            model.select("Idea.md")
            model.text = "Protected version"
            let draft = try #require(model.recoverable.first)
            let file = directory.appendingPathComponent("Drafts/\(draft.id).json")
            try Data("damaged recovery".utf8).write(to: file)
            model.text = "Newest version"
            #expect(model.recoveryIssue != nil)
            #expect(model.save())
            #expect(!model.dirty)
            #expect(!model.conflict)
            #expect(model.recoveryIssue?.contains("file was saved") == true)
            #expect(try folder.read("Idea.md").text == "Newest version")
            #expect(try Data(contentsOf: file) == Data("damaged recovery".utf8))
        }
    }

    @Test func searchIsDebouncedCancellableAndDoesNotIncludeUnsavedDraftText() async throws {
        try await asyncFixture { root, folder, library in
            let model = LiveMarkdownStore(stateDirectory: root.appendingPathComponent("Recovery"))
            try model.open(folder.root, avoiding: library)
            model.query = "not present"
            model.query = "lights"
            try await waitForSearch(model)
            #expect(model.searchReport?.matches.map(\.path) == ["Work/Research.md"])
            model.select("Work/Research.md")
            model.text = "Unsaved unique word"
            model.query = "Unsaved"
            try await waitForSearch(model)
            #expect(model.searchReport?.matches.isEmpty == true)
            model.query = "lights"
            model.query = ""
            try await Task.sleep(for: .milliseconds(350))
            #expect(model.searchReport == nil)
            #expect(!model.searching)
            #expect(model.text == "Unsaved unique word")
            #expect(model.resolveDraft(.discard))
            let other = root.appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            model.query = "lights"
            try model.open(other, avoiding: library)
            try await Task.sleep(for: .milliseconds(350))
            #expect(model.query.isEmpty)
            #expect(model.searchReport == nil)
        }
    }

    @Test func nativeWindowShowsSearchResultsAndRecoveredTextWithoutChangingDisk() async throws {
        try await asyncFixture { root, folder, library in
            _ = NSApplication.shared
            let directory = root.appendingPathComponent("Recovery")
            let first = LiveMarkdownStore(stateDirectory: directory)
            try first.open(folder.root, avoiding: library)
            first.select("Idea.md")
            first.text = "# Recovered Markdown\n\nYour unsaved words are protected locally."
            let model = LiveMarkdownStore(stateDirectory: directory)
            model.reopenLast(avoiding: library)
            model.query = "lights"
            try await waitForSearch(model)
            let defaultsName = "DeltosMarkdownDaily-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set("Light", forKey: "folioTheme")
            try LibraryStorage(url: library).save(.starter())
            let store = NotesStore(storage: LibraryStorage(url: library), preferences: defaults)
            let host = NSHostingView(rootView: LiveMarkdownView(model: model).environmentObject(store).defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 850),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 1240, height: 850)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            @MainActor func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { descendants($0) }
            }
            let source = try #require(descendants(host).compactMap { $0 as? NSTextView }.first {
                $0.string.contains("Your unsaved words")
            })
            #expect(source.isEditable)
            #expect(source.bounds.width >= 220)
            let search = try #require(descendants(host).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == "Search saved Markdown files"
            })
            #expect(search.stringValue == "lights")
            #expect(search.bounds.width >= 150)
            #expect(model.searchReport?.matches.map(\.path) == ["Work/Research.md"])
            #expect(model.dirty)
            #expect(model.recoveryIssue == nil)
            #expect(try folder.read("Idea.md").text == "Original idea")
            let web = try #require(descendants(host).compactMap { $0 as? WKWebView }.first)
            var ready = false
            for _ in 0..<100 {
                let contents = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
                if contents.contains("protected locally") { ready = true; break }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(ready)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let preview = try await web.takeSnapshot(configuration: nil)
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            var rect = web.convert(web.bounds, to: host)
            if host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            preview.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            try png.write(to: package.appendingPathComponent("dist/Deltos-markdown-daily-preview.png"))
            window.makeFirstResponder(source)
            source.setSelectedRange(NSRange(location: source.string.utf16.count, length: 0))
            source.insertText("\nTyped in the native window.", replacementRange: source.selectedRange())
            for _ in 0..<50 where !model.text.contains("Typed in the native window.") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.text.contains("Typed in the native window."))
            let restarted = LiveMarkdownStore(stateDirectory: directory)
            restarted.reopenLast(avoiding: library)
            #expect(restarted.text == model.text)
            #expect(restarted.dirty)
            #expect(try folder.read("Idea.md").text == "Original idea")
        }
    }

    private func waitForSearch(_ model: LiveMarkdownStore) async throws {
        for _ in 0..<100 where model.searching { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!model.searching)
        #expect(model.searchError == nil)
    }

    private func fixture(_ action: (URL, LiveMarkdownFolder, URL) throws -> Void) throws {
        let root = try prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root, LiveMarkdownFolder(root: root.appendingPathComponent("Markdown")), root.appendingPathComponent("Local/library.json"))
    }

    private func asyncFixture(_ action: (URL, LiveMarkdownFolder, URL) async throws -> Void) async throws {
        let root = try prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root, LiveMarkdownFolder(root: root.appendingPathComponent("Markdown")), root.appendingPathComponent("Local/library.json"))
    }

    private func prepare() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Markdown"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Local"), withIntermediateDirectories: false)
        try Data("Normal library remains untouched".utf8).write(to: root.appendingPathComponent("Local/library.json"))
        let folder = try LiveMarkdownFolder(root: root.appendingPathComponent("Markdown"))
        try folder.createNote(at: "Idea.md", text: "Original idea")
        try folder.createDirectory(at: "Work")
        try folder.createNote(at: "Work/Research.md", text: "Northern lights research")
        return root
    }
}
