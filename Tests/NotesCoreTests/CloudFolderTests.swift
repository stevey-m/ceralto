import Foundation
import NotesCore
import Testing
@testable import Folio

@MainActor
struct CloudFolderTests {
    @Test func cloudFolderConnectionRestoresAndDisconnectDoesNotRemoveNotesOrRemoteFiles() throws {
        try withStore { store, storage, defaults, cloud in
            let before = store.library
            try store.connectSyncFolder(cloud)
            #expect(store.syncFolderName == cloud.lastPathComponent)
            #expect(store.syncMessage.contains("not verified"))
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.syncFolderName == cloud.lastPathComponent)
            #expect(restarted.syncMessage.contains("not verified"))
            let marker = cloud.appendingPathComponent("keep.txt")
            try Data("Keep this file".utf8).write(to: marker)
            restarted.disconnectSyncFolder()
            #expect(restarted.syncFolderName == nil)
            #expect(restarted.library == before)
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let final = NotesStore(storage: storage, preferences: defaults)
            #expect(final.syncFolderName == nil)
        }
    }

    @Test func rejectsLibraryOverlapFilesAndMissingFoldersWithoutReplacingConnection() throws {
        try withStore { store, storage, _, cloud in
            try store.connectSyncFolder(cloud)
            let local = storage.url.deletingLastPathComponent()
            let nested = local.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for folder in [local, local.deletingLastPathComponent(), nested, storage.url,
                           cloud.appendingPathComponent("missing")] {
                #expect(throws: (any Error).self) { try store.connectSyncFolder(folder) }
                #expect(store.syncFolderName == cloud.lastPathComponent)
            }
            let linked = cloud.appendingPathComponent("library-link")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: local)
            #expect(throws: (any Error).self) { try store.connectSyncFolder(linked) }
        }
    }

    @Test func datedBackupsAreDistinctRestorableAndDoNotModifyLibraryOrSyncState() throws {
        try withStore { store, storage, _, cloud in
            let before = store.library
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try store.exportDatedBackup(to: cloud, on: date)
            let second = try store.exportDatedBackup(to: cloud, on: date)
            #expect(first != second)
            #expect(first.lastPathComponent.hasPrefix("Ceralto Backup 2023-11-14"))
            #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("library.json").path))
            #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("library.json").path))
            let result = try LibraryBackup.imported(from: first,
                importsDirectory: storage.url.deletingLastPathComponent().appendingPathComponent("Imports"))
            #expect(result.notes.map(\.title) == before.notes.map(\.title))
            #expect(result.notes.map(\.body) == before.notes.map(\.body))
            #expect(store.library == before)
            #expect(store.syncFolderName == nil)
            let saved = try storage.load()
            #expect(saved == before)
        }
    }

    @Test func localExchangeNeverClaimsCloudDeliveryIncludingConflictsAndReadonlyPulls() throws {
        try withStore { store, storage, defaults, cloud in
            let message = store.folderExchangeMessage(at: "10:00", conflicts: 2)
            #expect(message.contains("completed locally"))
            #expect(message.contains("2 conflicts preserved"))
            #expect(message.contains("Cloud upload and delivery are not verified"))
            let reader = NotesStore(storage: storage, readOnly: true, preferences: defaults)
            #expect(reader.folderExchangeMessage(at: "10:00", conflicts: 0).contains("read locally"))
            #expect(throws: (any Error).self) { try reader.exportDatedBackup(to: cloud) }
            #expect(SettingsSection.matching("dropbox") == [.sync])
            #expect(SettingsSection.matching("onedrive") == [.sync])
            #expect(SettingsSection.matching("google drive") == [.sync])
        }
    }

    @Test func localFolderRoundTripDoesNotRequireAProviderSDK() throws {
        try withStore { store, storage, _, cloud in
            let assets = storage.url.deletingLastPathComponent().appendingPathComponent("Assets")
            let sent = try FolderSync.synchronize(store.library, folder: cloud,
                                                 assets: assets.appendingPathComponent("writer"))
            let received = try FolderSync.pull(Library(notebooks: []), folder: cloud,
                                                assets: assets.appendingPathComponent("reader"))
            #expect(received.library.notes == sent.library.notes)
            #expect(received.conflicts == 0)
        }
    }

    private func withStore(_ action: (NotesStore, LibraryStorage, UserDefaults, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let storage = LibraryStorage(url: root.appendingPathComponent("local/library.json"))
        let suite = "FolioCloudFolders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(NotesStore(storage: storage, preferences: defaults), storage, defaults, cloud)
    }
}
