import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct ScheduledFolderSyncTests {
    @Test func manualExchangeUsesSchedulerAndRestoresPersistedPreference() async throws {
        try await fixture { store, storage, defaults, cloud, _ in
            #expect(!store.syncManager.schedule.enabled)
            try store.connectSyncFolder(cloud)
            store.syncManager.configure(enabled: true, minutes: 30)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncManager.status == .idle)
            #expect(store.syncManager.schedule.lastSuccess != nil)
            #expect(store.syncManager.nextAttempt != nil)
            #expect(store.library.folderSync != nil)
            #expect(try storage.load() == store.library)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.syncManager.connected)
            #expect(restarted.syncManager.schedule.enabled)
            #expect(restarted.syncManager.schedule.minutes == 30)
            #expect(restarted.syncManager.schedule.lastSuccess == store.syncManager.schedule.lastSuccess)
            #expect(restarted.syncManager.nextAttempt == store.syncManager.nextAttempt)
            restarted.disconnectSyncFolder()
            #expect(restarted.syncManager.nextAttempt == nil)
            #expect(restarted.library == store.library)
            #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Folio Sync").path))
        }
    }

    @Test func unsavedMainThreadEditsAreNotReplacedByAnOffMainResult() async throws {
        try await fixture { store, storage, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            let gate = FolderExchangeGate()
            defer { gate.finish() }
            store.syncTransport = { snapshot, _, _, _ in try await gate.exchange(snapshot) }
            store.syncNow()
            await gate.waitUntilStarted()
            let id = try #require(store.library.notes.first?.id)
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            store.update(id) { $0.body = "Unsaved main-thread draft" }
            #expect(store.hasUnsavedChanges)
            let edited = store.library
            gate.finish()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.library == edited)
            #expect(store.library.notes.first?.body == "Unsaved main-thread draft")
            #expect(store.hasUnsavedChanges)
            #expect(store.syncManager.status == .deferred)
            #expect(store.syncManager.schedule.lastSuccess == nil)
            #expect(store.syncMessage.contains("Notes changed"))
            try FileManager.default.removeItem(at: storage.url)
            store.save()
            #expect(!store.hasUnsavedChanges)
            #expect(try storage.load()?.notes.first?.body == "Unsaved main-thread draft")
        }
    }

    @Test func disconnectCancelsApplicationOfPendingResultAndDoesNotDeleteSharedFiles() async throws {
        try await fixture { store, storage, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            let before = store.library
            let marker = cloud.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: marker)
            let gate = FolderExchangeGate()
            defer { gate.finish() }
            store.syncTransport = { snapshot, _, _, _ in try await gate.exchange(snapshot) }
            store.syncNow()
            await gate.waitUntilStarted()
            store.disconnectSyncFolder()
            #expect(store.syncFolderName == nil)
            #expect(store.syncManager.isRunning)
            #expect(throws: (any Error).self) { try store.connectSyncFolder(cloud) }
            store.syncNow()
            gate.finish()
            await store.syncManager.waitForCurrentExchange()
            #expect(!store.isSyncing)
            #expect(!store.syncManager.isRunning)
            #expect(store.syncManager.status == .disconnected)
            #expect(store.syncManager.schedule.lastSuccess == nil)
            #expect(store.library == before)
            #expect(try storage.load() == before)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            #expect(store.syncManager.nextAttempt == nil)
        }
    }

    @Test func externalDiskChangeDuringExchangeIsNotOverwritten() async throws {
        try await fixture { store, storage, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            let gate = FolderExchangeGate()
            defer { gate.finish() }
            store.syncTransport = { snapshot, _, _, _ in try await gate.exchange(snapshot) }
            let before = store.library
            store.syncNow()
            await gate.waitUntilStarted()
            var external = before
            external.notes[0].body = "External disk-only edit"
            try storage.save(external)
            gate.finish()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.library == before)
            #expect(try storage.load() == external)
            #expect(store.syncManager.status == .deferred)
            #expect(store.syncManager.schedule.lastSuccess == nil)
            #expect(store.syncMessage.contains("file changed"))
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(try storage.load() == external)
            #expect(store.syncManager.status == .deferred)
            #expect(store.syncManager.message.contains("restart Ceralto"))
        }
    }

    @Test func manualCancelKeepsConnectionAndRejectsLateTransportResult() async throws {
        try await fixture { store, storage, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            let before = store.library
            let gate = FolderExchangeGate()
            defer { gate.finish() }
            store.syncTransport = { snapshot, _, _, _ in try await gate.exchange(snapshot) }
            store.syncNow()
            await gate.waitUntilStarted()
            store.syncManager.cancel()
            store.syncNow()
            #expect(gate.calls == 1)
            #expect(store.isSyncing)
            gate.finish()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncFolderName == cloud.lastPathComponent)
            #expect(store.syncManager.status == .cancelled)
            #expect(store.syncManager.schedule.lastSuccess == nil)
            #expect(store.library == before)
            #expect(try storage.load() == before)
        }
    }

    @Test func missingFolderIsExplicitlyOfflineAndManualRetryRecovers() async throws {
        try await fixture { store, _, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            store.syncManager.configure(enabled: true)
            let before = store.library
            try FileManager.default.removeItem(at: cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncManager.status == .offline)
            #expect(store.syncManager.schedule.lastSuccess == nil)
            #expect(store.syncManager.nextAttempt != nil)
            #expect(store.library == before)
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncManager.status == .idle)
            #expect(store.syncManager.schedule.lastSuccess != nil)
            #expect(store.syncMessage.contains("not verified"))
        }
    }

    @Test func realConflictReviewKeepsBothVariantsAndResolutionSurvivesExchangeAndRestart() async throws {
        try await fixture { store, storage, defaults, cloud, root in
            let attachment = root.appendingPathComponent("fixture.txt")
            let attachmentBytes = Data("Isolated sync attachment fixture".utf8)
            try attachmentBytes.write(to: attachment)
            try store.attachFiles([attachment], to: #require(store.library.notes.first?.id))
            try store.connectSyncFolder(cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            var other = try FolderSync.pull(Library(notebooks: []), folder: cloud,
                                            assets: root.appendingPathComponent("other-assets")).library
            let id = try #require(store.library.notes.first?.id)
            store.update(id) { $0.body += "\nFirst Mac edit"; $0.title = "First variant" }
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            other.notes[0].body += "\nSecond Mac edit"
            other.notes[0].title = "Second variant"
            other.notes[0].updatedAt = Date(timeIntervalSince1970: 100)
            _ = try FolderSync.synchronize(other, folder: cloud, assets: root.appendingPathComponent("other-assets"))
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncConflictNotes.count == 2)
            #expect(store.syncConflictSummaries.count == 1)
            #expect(store.syncConflictSummaries.first?.variantIDs.count == 2)
            #expect(store.syncConflictSummaries.first?.includesDeletion == false)
            #expect(store.syncConflictNotes.contains { $0.body.contains("First Mac edit") })
            #expect(store.syncConflictNotes.contains { $0.body.contains("Second Mac edit") })
            let before = store.library.notes
            for note in before {
                try expectAttachment(attachmentBytes, in: note)
            }
            store.query = "unrelated search"
            store.reviewSyncConflict(try #require(store.syncConflictNotes.first?.id))
            #expect(store.query.isEmpty)
            #expect(store.selectedNote?.tags.contains("sync-conflict") == true)
            try store.keepSyncConflictVariants(Set(store.syncConflictNotes.map(\.id)))
            #expect(store.syncConflictNotes.isEmpty)
            #expect(store.syncConflictSummaries.isEmpty)
            #expect(Set(store.library.notes.map(\.id)) == Set(before.map(\.id)))
            for old in before {
                let kept = try #require(store.library.notes.first { $0.id == old.id })
                #expect(kept.body == old.body)
                #expect(kept.title == old.title)
                #expect(kept.history == old.history)
                #expect(kept.importedSourceURL == old.importedSourceURL)
                #expect(kept.importedRootURL == old.importedRootURL)
            }
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncConflictNotes.isEmpty)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.syncConflictNotes.isEmpty)
            #expect(restarted.library.notes.count == before.count)
            let pulled = try FolderSync.pull(Library(notebooks: []), folder: cloud,
                                             assets: root.appendingPathComponent("reader-assets"))
            #expect(pulled.library.notes.allSatisfy { !$0.tags.contains("sync-conflict") })
            #expect(pulled.library.notes.contains { $0.body.contains("First Mac edit") })
            #expect(pulled.library.notes.contains { $0.body.contains("Second Mac edit") })
            // An unchanged pre-resolution peer must not recreate reviewed conflicts.
            let staleRejoin = try FolderSync.synchronize(other, folder: cloud,
                                                        assets: root.appendingPathComponent("other-assets")).library
            #expect(staleRejoin.notes.allSatisfy { !$0.tags.contains("sync-conflict") })
            let repeatExchange = try FolderSync.synchronize(staleRejoin, folder: cloud,
                                                            assets: root.appendingPathComponent("other-assets")).library
            #expect(repeatExchange.notes.count == before.count)
            #expect(repeatExchange.notes.allSatisfy { !$0.tags.contains("sync-conflict") })
            for note in repeatExchange.notes { try expectAttachment(attachmentBytes, in: note) }
        }
    }

    @Test func conflictInTrashCanBeOpenedAndResolutionFailurePreservesMarkers() async throws {
        try await fixture { store, storage, _, _, _ in
            let id = try #require(store.library.notes.first?.id)
            store.update(id) { $0.tags = ["sync-conflict", "work"] }
            store.trash(id)
            store.reviewSyncConflict(id)
            #expect(store.scope == .trash)
            #expect(store.selectedNoteID == id)
            #expect(store.syncConflictNotes.map(\.id) == [id])
            let before = store.library
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.keepSyncConflictVariants([id]) }
            #expect(store.library == before)
            #expect(store.syncConflictNotes.count == 1)
        }
    }

    @Test func editVersusDeletionHasExplicitSummaryAndKeepsEditedContent() async throws {
        try await fixture { store, storage, defaults, cloud, root in
            try store.connectSyncFolder(cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            var deleting = try FolderSync.pull(Library(notebooks: []), folder: cloud,
                                               assets: root.appendingPathComponent("deleting-assets")).library
            let id = try #require(store.library.notes.first?.id)
            store.update(id) { $0.body = "Edited while the other Mac deleted it" }
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            deleting.notes.removeAll()
            _ = try FolderSync.synchronize(deleting, folder: cloud, assets: root.appendingPathComponent("deleting-assets"))
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncConflictNotes.count == 1)
            #expect(store.syncConflictNotes.first?.body == "Edited while the other Mac deleted it")
            #expect(store.syncConflictSummaries.first?.includesDeletion == true)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.syncConflictSummaries.first?.includesDeletion == true)
            #expect(restarted.syncConflictSummaries.first?.variantIDs == [id])
            try store.keepSyncConflictVariants([id])
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncConflictSummaries.isEmpty)
            #expect(store.library.notes.first?.body == "Edited while the other Mac deleted it")
        }
    }

    @Test func unreadableOrCorruptSnapshotReportsFailureWithoutReplacingNotesOrSuccessTime() async throws {
        try await fixture { store, _, _, cloud, _ in
            try store.connectSyncFolder(cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            let before = store.library
            let success = store.syncManager.schedule.lastSuccess
            let snapshots = cloud.appendingPathComponent("Folio Sync/snapshots")
            let snapshot = try #require(FileManager.default.contentsOfDirectory(at: snapshots,
                includingPropertiesForKeys: nil).first)
            try Data("damaged snapshot".utf8).write(to: snapshot.appendingPathComponent("library.json"))
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncManager.status == .failed)
            #expect(store.syncManager.message.contains("incomplete or damaged"))
            #expect(store.syncManager.schedule.lastSuccess == success)
            #expect(store.library == before)
        }
    }

    @Test func concurrentTrashAndEditPreserveBothVariantsIncludingTrashState() async throws {
        try await fixture { store, _, _, cloud, root in
            try store.connectSyncFolder(cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            var other = try FolderSync.pull(Library(notebooks: []), folder: cloud,
                                            assets: root.appendingPathComponent("other-assets")).library
            let id = try #require(store.library.notes.first?.id)
            store.update(id) { $0.body = "Active edited version" }
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            other.notes[0].body = "Trashed version"
            other.notes[0].deletedAt = Date(timeIntervalSince1970: 100)
            other.notes[0].updatedAt = Date(timeIntervalSince1970: 100)
            _ = try FolderSync.synchronize(other, folder: cloud, assets: root.appendingPathComponent("other-assets"))
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            #expect(store.syncConflictNotes.count == 2)
            let trash = try #require(store.syncConflictNotes.first { $0.body == "Trashed version" })
            #expect(trash.deletedAt != nil)
            store.reviewSyncConflict(trash.id)
            #expect(store.scope == .trash)
            #expect(store.selectedNoteID == trash.id)
            try store.keepSyncConflictVariants(Set(store.syncConflictNotes.map(\.id)))
            #expect(store.library.notes.first { $0.id == trash.id }?.deletedAt == trash.deletedAt)
            #expect(Set(store.library.notes.map(\.body)) == ["Active edited version", "Trashed version"])
        }
    }

    @Test func readOnlyStoreUsesSameSerialPathWithoutPublishingSnapshots() async throws {
        try await fixture { store, _, defaults, cloud, root in
            try store.connectSyncFolder(cloud)
            store.syncNow()
            await store.syncManager.waitForCurrentExchange()
            let snapshots = cloud.appendingPathComponent("Folio Sync/snapshots")
            let before = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
            let readerStorage = LibraryStorage(url: root.appendingPathComponent("reader/library.json"))
            try readerStorage.save(Library(notebooks: [Notebook(name: "Reader")]))
            let reader = NotesStore(storage: readerStorage, readOnly: true, preferences: defaults)
            try reader.connectSyncFolder(cloud)
            reader.syncNow()
            await reader.syncManager.waitForCurrentExchange()
            #expect(reader.syncManager.status == .idle)
            #expect(reader.library.notes.map(\.body) == store.library.notes.map(\.body))
            #expect(reader.syncMessage.contains("read locally"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path) == before)
            #expect(throws: (any Error).self) { try reader.keepSyncConflictVariants([]) }
        }
    }

    private func fixture(_ action: @MainActor (NotesStore, LibraryStorage, UserDefaults, URL, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/sync-test-fixtures/\(UUID().uuidString)", isDirectory: true)
        let suite = "DeltosScheduledFolderSyncTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let storage = LibraryStorage(url: root.appendingPathComponent("local/library.json"))
        let notebook = Notebook(name: "Sync test notebook")
        try storage.save(Library(notebooks: [notebook],
                                 notes: [Note(notebookID: notebook.id, title: "Test", body: "Original")]))
        let store = NotesStore(storage: storage, preferences: defaults)
        try await action(store, storage, defaults, cloud, root)
        store.syncManager.stop()
    }

    private func expectAttachment(_ expected: Data, in note: Note) throws {
        let root = try #require(note.importedRootURL)
        let source = try #require(note.importedSourceURL)
        let resources = ImportedResources(source: source, root: root)
        let page = try FormattedPage(markdown: note.body)
        let reference = try #require(page.blocks.flatMap(\.runs).first { $0.link != nil }?.link)
        let actual = try #require(resources.localURL(for: reference))
        #expect(try Data(contentsOf: actual) == expected)
    }
}

@MainActor
private final class FolderExchangeGate {
    private var completion: CheckedContinuation<FolderSyncResult, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var snapshot: Library?
    private(set) var calls = 0

    func exchange(_ library: Library) async throws -> FolderSyncResult {
        calls += 1
        snapshot = library
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        guard var snapshot else { return }
        snapshot.notes[0].body = "Stale result from off-main exchange"
        completion?.resume(returning: FolderSyncResult(library: snapshot, conflicts: 0))
        completion = nil
    }
}
