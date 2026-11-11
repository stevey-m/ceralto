import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct HistoryPolicyTests {
    @Test func captureUsesConfiguredIntervalCountPauseAndForcedRestoreSafety() throws {
        let notebook = UUID()
        var note = Note(notebookID: notebook, body: "Original")
        let policy = HistoryPolicy(maximumCheckpoints: 5, intervalSeconds: 60)
        let start = Date(timeIntervalSince1970: 10_000)
        for index in 0..<8 {
            let previous = note
            note.body = "Edit \(index)"
            note.recordRevision(of: previous, now: start.addingTimeInterval(Double(index * 60)), policy: policy)
        }
        #expect(note.history?.count == 5)
        #expect(note.history?.first?.body == "Edit 2")
        let before = note
        note.body = "Too soon"
        note.recordRevision(of: before, now: start.addingTimeInterval(421), policy: policy)
        #expect(note.history == before.history)
        let paused = HistoryPolicy(enabled: false, maximumCheckpoints: 5, intervalSeconds: 60)
        let previous = note
        note.body = "After pause"
        note.recordRevision(of: previous, now: start.addingTimeInterval(999), policy: paused)
        #expect(note.history == previous.history)
        let current = note
        note.body = "Restored text"
        note.recordRevision(of: current, force: true, policy: paused)
        #expect(note.history?.count == 5)
        #expect(note.history?.last?.body == "After pause")
        #expect(throws: (any Error).self) { try HistoryPolicy(maximumCheckpoints: -1).validate() }
        #expect(throws: (any Error).self) { try HistoryPolicy(intervalSeconds: 0).validate() }
    }

    @Test func pruningRequiresConfirmationPersistsAndRollsBackOnSaveFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeltosHistoryPolicy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        var library = Library.starter()
        library.notes[0].history = (0..<12).map { index in
            NoteRevision(note: Note(notebookID: library.notebooks[0].id, body: "Version \(index)"))
        }
        try storage.save(library)
        let store = NotesStore(storage: storage, preferences: defaults)
        let reduced = HistoryPolicy(maximumCheckpoints: 5, intervalSeconds: 60)
        #expect(store.historyPruningCount(for: reduced) == 7)
        #expect(throws: (any Error).self) { try store.applyHistoryPolicy(reduced) }
        #expect(store.library == library)
        #expect(defaults.object(forKey: HistoryPolicy.preferenceKey) == nil)
        try FileManager.default.removeItem(at: storage.url)
        try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.applyHistoryPolicy(reduced, confirmedPruning: true) }
        #expect(store.library == library)
        #expect(store.historyPolicy == .standard)
        #expect(defaults.object(forKey: HistoryPolicy.preferenceKey) == nil)
        try FileManager.default.removeItem(at: storage.url)
        try store.applyHistoryPolicy(reduced, confirmedPruning: true)
        #expect(store.library.notes[0].history?.count == 5)
        #expect(store.library.notes[0].history?.first?.body == "Version 7")
        let reopened = NotesStore(storage: storage, preferences: defaults)
        #expect(reopened.historyPolicy == reduced)
        #expect(reopened.library.notes[0].history?.count == 5)
        let noteID = reopened.library.notes[0].id
        try reopened.applyHistoryPolicy(HistoryPolicy(enabled: false, maximumCheckpoints: 5))
        reopened.update(noteID) { $0.body = "No automatic history" }
        #expect(reopened.library.notes[0].history?.count == 5)
        let revision = try #require(reopened.library.notes[0].history?.first)
        reopened.restoreRevision(revision, noteID: noteID)
        #expect(reopened.library.notes[0].history?.last?.body == "No automatic history")
    }

    @Test func unreadablePolicyIsPreservedAndPausesCaptureWithoutPruningOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeltosUnreadableHistory-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let invalid = Data("unreadable policy".utf8)
        defaults.set(invalid, forKey: HistoryPolicy.preferenceKey)
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        var library = Library.starter()
        library.notes[0].history = (0..<30).map { _ in NoteRevision(note: library.notes[0]) }
        try storage.save(library)
        let store = NotesStore(storage: storage, preferences: defaults)
        #expect(!store.historyPolicyAvailable)
        #expect(!store.historyPolicy.enabled)
        #expect(store.errorMessage?.contains("paused") == true)
        #expect(store.library.notes[0].history?.count == 30)
        store.update(library.notes[0].id) { $0.body = "Changed" }
        #expect(store.library.notes[0].history?.count == 30)
        #expect(defaults.data(forKey: HistoryPolicy.preferenceKey) == invalid)
    }
}
