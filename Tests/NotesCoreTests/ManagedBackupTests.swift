import Foundation
import NotesCore
import Testing
@testable import Folio

struct ManagedBackupTests {
    @Test func verifiesCompleteBackupAndDetectsDamageBeforeRetentionDeletesAnything() throws {
        try withDirectory { parent in
            let owner = UUID()
            let library = Library.starter()
            let first = try ManagedBackups.create(library, in: parent, owner: owner,
                                                  date: Date(timeIntervalSince1970: 100))
            let second = try ManagedBackups.create(library, in: parent, owner: owner,
                                                   date: Date(timeIntervalSince1970: 200))
            #expect(first.notes == library.notes.count)
            #expect(first.notebooks == library.notebooks.count)
            try Data("damaged".utf8).write(to: first.folder.appendingPathComponent("library.json"))
            #expect(throws: (any Error).self) { try ManagedBackups.inspect(first.folder, owner: owner) }
            let imports = parent.appendingPathComponent("imports")
            #expect(throws: (any Error).self) { try LibraryBackup.imported(from: first.folder, importsDirectory: imports) }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: imports.path)
            #expect(leftovers.isEmpty)
            #expect(throws: (any Error).self) { try ManagedBackups.prune(in: parent, owner: owner, keeping: 1) }
            #expect(FileManager.default.fileExists(atPath: first.folder.path))
            #expect(FileManager.default.fileExists(atPath: second.folder.path))
        }
    }

    @Test func retentionIsScopedAndKeepsNewestVerifiedBackupsWithoutTouchingOtherFiles() throws {
        try withDirectory { parent in
            let owner = UUID()
            let library = Library.starter()
            let older = try ManagedBackups.create(library, in: parent, owner: owner,
                                                  date: Date(timeIntervalSince1970: 100))
            let newer = try ManagedBackups.create(library, in: parent, owner: owner,
                                                  date: Date(timeIntervalSince1970: 200))
            let other = try ManagedBackups.create(library, in: parent, owner: UUID())
            let manual = parent.appendingPathComponent("manual-backup")
            try LibraryBackup.export(library, to: manual)
            let unrelated = ManagedBackups.directory(in: parent, owner: owner).appendingPathComponent("readme.txt")
            try Data("keep".utf8).write(to: unrelated)
            try ManagedBackups.prune(in: parent, owner: owner, keeping: 1)
            #expect(!FileManager.default.fileExists(atPath: older.folder.path))
            #expect(FileManager.default.fileExists(atPath: newer.folder.path))
            #expect(FileManager.default.fileExists(atPath: other.folder.path))
            #expect(FileManager.default.fileExists(atPath: manual.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(throws: (any Error).self) { try ManagedBackups.prune(in: parent, owner: owner, keeping: 0) }
            #expect(throws: (any Error).self) { try ManagedBackups.inspect(newer.folder, owner: UUID()) }
        }
    }

    @Test func originalAttachmentsAreVerifiedAndRestorableAsCopies() throws {
        try withDirectory { parent in
            let source = parent.appendingPathComponent("originals")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let image = Data([1, 2, 3, 4, 5])
            try image.write(to: source.appendingPathComponent("image.png"))
            let notebook = Notebook(name: "Keep/Images")
            let revision = NoteRevision(note: Note(notebookID: notebook.id, title: "Earlier", body: "Original words"))
            let note = Note(notebookID: notebook.id, title: "Keep image", body: "![Image](image.png)",
                            tags: ["keep"], isPinned: true, deletedAt: Date(timeIntervalSince1970: 100),
                            importedSourceURL: source.appendingPathComponent("note.md"), importedRootURL: source)
            var withHistory = note
            withHistory.history = [revision]
            let owner = UUID()
            try FileManager.default.createDirectory(at: parent.appendingPathComponent("backups"), withIntermediateDirectories: true)
            let backup = try ManagedBackups.create(Library(notebooks: [notebook], notes: [withHistory]),
                in: parent.appendingPathComponent("backups"), owner: owner)
            let restored = try LibraryBackup.imported(from: backup.folder, importsDirectory: parent.appendingPathComponent("imports"))
            let recovered = try #require(restored.notes.first)
            #expect(recovered.id != note.id)
            #expect(recovered.body == note.body)
            #expect(recovered.tags == note.tags)
            #expect(recovered.isPinned)
            #expect(recovered.deletedAt == note.deletedAt)
            #expect(recovered.history == [revision])
            #expect(recovered.createdAt == note.createdAt)
            #expect(restored.notebooks.first?.name == notebook.name)
            let root = try #require(recovered.importedRootURL)
            let copied = try Data(contentsOf: root.appendingPathComponent("image.png"))
            #expect(copied == image)
            let loaded = try tryLoad(backup.folder)
            let portable = try #require(loaded)
            let resource = try #require(portable.notes.first?.importedRootURL)
            try Data([9]).write(to: backup.folder.appendingPathComponent(resource.relativeString).appendingPathComponent("image.png"))
            #expect(throws: (any Error).self) { try ManagedBackups.inspect(backup.folder, owner: owner) }
        }
    }

    @Test func symlinkedManagedRootIsRejectedBeforeWritingAnyBackup() throws {
        try withDirectory { parent in
            let external = parent.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let destination = parent.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Deltos Backups"),
                                                       withDestinationURL: external)
            #expect(throws: (any Error).self) {
                try ManagedBackups.create(.starter(), in: destination, owner: UUID())
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: external.path)
            #expect(!files.contains { $0.hasPrefix(".incomplete") })
        }
    }

    private func tryLoad(_ folder: URL) throws -> Library? {
        try LibraryStorage(url: folder.appendingPathComponent("library.json")).load()
    }

    private func withDirectory(_ action: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try action(parent)
    }
}

@MainActor
struct BackupScheduleTests {
    @Test func scheduledBackupsRespectIntervalPersistStatusAndRestoreCopies() async throws {
        try await withManager { store, manager, defaults, parent in
            try manager.connect(parent)
            manager.configure(enabled: true, hours: 1, keep: 2)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            await manager.tick(on: date)
            #expect(manager.backups.count == 1)
            #expect(manager.schedule.lastSuccess == date)
            #expect(manager.message.contains("Cloud delivery is not verified"))
            await manager.tick(on: date.addingTimeInterval(600))
            #expect(manager.backups.count == 1)
            await manager.tick(on: date.addingTimeInterval(3600))
            #expect(manager.backups.count == 2)
            await manager.tick(on: date.addingTimeInterval(7200))
            #expect(manager.backups.count == 2)
            let restored = BackupManager(store: store, defaults: defaults)
            await restored.refresh()
            #expect(restored.schedule.enabled)
            #expect(restored.backups.count == 2)
            let backup = try #require(manager.backups.first)
            let before = store.library.notes
            await manager.restore(backup)
            #expect(store.library.notes.count == before.count * 2)
            #expect(before.allSatisfy { note in store.library.notes.contains { $0 == note } })
            #expect(manager.message.contains("Existing notes were preserved"))
        }
    }

    @Test func damagedOlderBackupBlocksRetentionWithoutDeletingIt() async throws {
        try await withManager { _, manager, _, parent in
            try manager.connect(parent)
            manager.configure(enabled: true, hours: 1, keep: 1)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            await manager.tick(on: date)
            let first = try #require(manager.backups.first)
            try Data("damaged".utf8).write(to: first.folder.appendingPathComponent("library.json"))
            await manager.tick(on: date.addingTimeInterval(3600))
            #expect(manager.message.contains("failed"))
            #expect(manager.schedule.lastSuccess == date.addingTimeInterval(3600),
                    "The new backup succeeded, even though retention of older copies failed.")
            #expect(FileManager.default.fileExists(atPath: first.folder.path))
            #expect(!manager.busy)
        }
    }

    @Test func missingDestinationDoesNotAdvanceSuccessOrRecreateTheFolder() async throws {
        try await withManager { store, manager, _, parent in
            try manager.connect(parent)
            manager.configure(enabled: true, hours: 1)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            await manager.tick(on: date)
            let moved = parent.deletingLastPathComponent().appendingPathComponent("moved-backups")
            try FileManager.default.moveItem(at: parent, to: moved)
            await manager.tick(on: date.addingTimeInterval(3600))
            #expect(manager.schedule.lastSuccess == date)
            #expect(manager.message.contains("failed"))
            #expect(store.errorMessage != nil)
            #expect(!FileManager.default.fileExists(atPath: parent.path))
            let saved = try ManagedBackups.list(in: moved, owner: manager.schedule.owner)
            #expect(saved.count == 1)
        }
    }

    @Test func disabledScheduleNeverWritesAndReadOnlyStoreCannotConnect() async throws {
        try await withManager { store, manager, defaults, parent in
            try manager.connect(parent)
            await manager.tick()
            #expect(manager.backups.isEmpty)
            #expect(manager.schedule.lastSuccess == nil)
            let readOnly = NotesStore(storage: LibraryStorage(url: store.libraryURL), readOnly: true, preferences: defaults)
            #expect(readOnly.backupManager == nil)
            let blocked = BackupManager(store: readOnly, defaults: defaults)
            #expect(throws: (any Error).self) { try blocked.connect(parent) }
        }
    }

    @Test func unreadablePreferencesArePreservedAndDisabledUntilExplicitReset() async throws {
        try await withManager { store, _, defaults, _ in
            let data = Data(#"{"version":99}"#.utf8)
            defaults.set(data, forKey: BackupManager.key)
            let manager = BackupManager(store: store, defaults: defaults)
            #expect(!manager.available)
            await manager.tick()
            #expect(defaults.data(forKey: BackupManager.key) == data)
            manager.resetSettings()
            #expect(manager.available)
            #expect(!manager.schedule.enabled)
            #expect(defaults.object(forKey: BackupManager.key) == nil)
        }
    }

    private func withManager(_ action: @MainActor (NotesStore, BackupManager, UserDefaults, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let suite = "DeltosBackups-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotesStore(storage: LibraryStorage(url: root.appendingPathComponent("local/library.json")), preferences: defaults)
        let manager = BackupManager(store: store, defaults: defaults)
        try await action(store, manager, defaults, parent)
    }
}
