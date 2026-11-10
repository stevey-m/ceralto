import AppKit
import NotesCore
import SwiftUI

struct BackupSchedule: Codable {
    var version = 1
    var owner = UUID()
    var bookmark: Data?
    var enabled = false
    var hours = 24
    var keep = 10
    var lastSuccess: Date?

    func validate() throws {
        guard version == 1, [1, 6, 24].contains(hours), (1...100).contains(keep),
              !enabled || bookmark != nil else { throw NoteWorkflowError("Unsupported or invalid backup settings.") }
    }
}

@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var schedule = BackupSchedule()
    @Published private(set) var available = true
    @Published private(set) var busy = false
    @Published private(set) var message = "Choose a separate backup folder to begin."
    @Published private(set) var backups: [ManagedBackup] = []
    @Published private(set) var folderName: String?
    private weak var store: NotesStore?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var folder: URL?
    private var lastAttempt: Date?
    static let key = "completeBackupSchedule"
    var folderPath: String? { folder?.path }

    init(store: NotesStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        do {
            if let stored = defaults.object(forKey: Self.key) {
                guard let data = stored as? Data else { throw NoteWorkflowError("Backup settings are not valid data.") }
                schedule = try JSONDecoder().decode(BackupSchedule.self, from: data)
            }
            try schedule.validate()
            if let bookmark = schedule.bookmark {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw NoteWorkflowError("Backup-folder access expired. Reconnect the folder.") }
                folder = url
                folderName = url.lastPathComponent
                message = "Backup folder connected. Open Files & Backups to verify its contents."
            }
        } catch {
            available = false
            message = "Backup settings could not be loaded. Saved data is preserved; scheduling is inactive. \(error.localizedDescription)"
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await refresh(); await tick() }
    }

    func configure(enabled: Bool? = nil, hours: Int? = nil, keep: Int? = nil) {
        guard available, !busy, store?.isReadOnly == false else {
            message = "Backup settings are unavailable while a backup is running, in a read-only library, or until saved settings are recovered."
            return
        }
        var candidate = schedule
        if let enabled { candidate.enabled = enabled }
        if let hours { candidate.hours = hours }
        if let keep { candidate.keep = keep }
        persist(candidate)
    }

    private func persist(_ candidate: BackupSchedule) {
        do {
            try candidate.validate()
            defaults.set(try JSONEncoder().encode(candidate), forKey: Self.key)
            schedule = candidate
        } catch { message = "Could not save backup settings: \(error.localizedDescription)" }
    }

    func connect(_ url: URL) throws {
        guard let store, !busy, !store.isReadOnly else { throw NoteWorkflowError("Backups are unavailable right now.") }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try store.validateCloudFolder(url)
        var candidate = schedule
        candidate.bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
        candidate.lastSuccess = nil
        try candidate.validate()
        defaults.set(try JSONEncoder().encode(candidate), forKey: Self.key)
        schedule = candidate
        available = true
        folder = url
        folderName = url.lastPathComponent
        backups = []
        message = "Backup folder connected. Refresh to verify existing managed backups."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a separate local or downloaded cloud folder. Only this library's verified managed backups are eligible for retention. Upload is not verified."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try connect(url)
            Task { await refresh() }
        }
        catch { message = "Could not connect backup folder: \(error.localizedDescription)" }
    }

    func tick(on date: Date = Date()) async {
        guard available, schedule.enabled, !busy,
              date.timeIntervalSince(lastAttempt ?? .distantPast) >= 300,
              date.timeIntervalSince(schedule.lastSuccess ?? .distantPast) >= Double(schedule.hours) * 3600 else { return }
        await backup(on: date)
    }

    func backup(on date: Date = Date()) async {
        guard available, !busy, let store, store.isLoaded, !store.isReadOnly, !store.isSyncing,
              let folder else {
            message = "Connect a backup folder and open an editable library; wait for sync or the current backup to finish."
            return
        }
        lastAttempt = date
        busy = true
        message = "Writing and verifying a complete local backup…"
        let snapshot = store.library
        let owner = schedule.owner
        let keep = schedule.keep
        let accessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            busy = false
        }
        do {
            try store.validateCloudFolder(folder)
            let created = try await Task.detached {
                try ManagedBackups.create(snapshot, in: folder, owner: owner, date: date)
            }.value
            var candidate = schedule
            candidate.lastSuccess = created.date
            persist(candidate)
            try await Task.detached { try ManagedBackups.prune(in: folder, owner: owner, keeping: keep) }.value
            backups = try await Task.detached { try ManagedBackups.list(in: folder, owner: owner) }.value
            message = "Complete backup verified locally at \(date.formatted()). Cloud delivery is not verified."
        } catch {
            message = "Backup or retention failed. Existing notes are unchanged. \(error.localizedDescription)"
            store.errorMessage = message
        }
    }

    func refresh() async {
        guard available, !busy, let folder else { return }
        busy = true
        defer { busy = false }
        let owner = schedule.owner
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        do {
            backups = try await Task.detached { try ManagedBackups.list(in: folder, owner: owner) }.value
            message = "\(backups.count) verified managed backups available locally."
        } catch {
            backups = []
            message = "Cannot verify the backup list; retention and restore must wait. \(error.localizedDescription)"
        }
    }

    func restore(_ backup: ManagedBackup) async {
        guard let folder, let store, !busy, store.isLoaded, !store.isReadOnly, !store.isSyncing else {
            message = "Open an editable library and wait for sync or backup to finish before recovery."
            return
        }
        busy = true
        defer { busy = false }
        let owner = schedule.owner
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await Task.detached { try ManagedBackups.inspect(backup.folder, owner: owner) }.value
            try store.importBackup(from: backup.folder)
            message = "Recovered notes added as copies. Existing notes were preserved."
        } catch { message = "Restore failed: \(error.localizedDescription)"; store.errorMessage = message }
    }

    func resetSettings() {
        guard !busy else { message = "Wait for the current backup before resetting settings."; return }
        defaults.removeObject(forKey: Self.key)
        schedule = BackupSchedule()
        available = true
        folder = nil
        folderName = nil
        backups = []
        message = "Settings reset. Existing backups were not deleted; use Import Deltos Backup to recover older sets."
    }
}

struct BackupReliabilitySettings: View {
    @ObservedObject var manager: BackupManager
    @ViewState private var restoring: ManagedBackup?
    @ViewState private var resetting = false

    var body: some View {
        Section("Scheduled complete backups") {
            LabeledContent("Folder", value: manager.folderName ?? "Not connected")
                .help(manager.folderPath ?? "Choose a separate backup folder")
            LabeledContent("Last complete backup", value: manager.schedule.lastSuccess?.formatted() ?? "Not yet backed up")
            Button("Choose Backup Folder…", action: manager.chooseFolder).disabled(manager.busy)
            Toggle("Back up while Deltos is open", isOn: Binding(
                get: { manager.schedule.enabled }, set: { manager.configure(enabled: $0) }
            )).disabled(!manager.available || manager.folderName == nil || manager.busy)
            Picker("Interval", selection: Binding(get: { manager.schedule.hours },
                                                  set: { manager.configure(hours: $0) })) {
                Text("Hourly").tag(1)
                Text("Every 6 hours").tag(6)
                Text("Daily").tag(24)
            }.disabled(!manager.available || manager.busy)
            Stepper("Keep \(manager.schedule.keep) managed backups",
                    value: Binding(get: { manager.schedule.keep }, set: { manager.configure(keep: $0) }), in: 1...100)
                .disabled(!manager.available || manager.busy)
            Text("Retention runs only after a new verified backup succeeds. It removes older verified backups in this library's managed set, never manual backups or unrelated files. Lowering the count takes effect after the next successful backup.")
                .font(.caption).foregroundStyle(.secondary)
            Button(manager.busy ? "Backing Up…" : "Back Up Now") { Task { await manager.backup() } }
                .disabled(manager.busy || !manager.available || manager.folderName == nil)
            Text(manager.message).textSelection(.enabled)
            if !manager.available {
                Button("Reset Unreadable Backup Settings…") { resetting = true }
            }
            Text("Runs only while the app is open. An overdue backup is attempted on launch or the next minute after waking. No background agent or upload confirmation. Complete library backups include notes, history and original attachments, not app settings or unsaved capture drafts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset backup settings?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive, action: manager.resetSettings)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scheduling is disabled and the saved configuration discarded. No backups are deleted. Older backup sets remain recoverable with Import Deltos Backup but will no longer be managed by this schedule.")
        }
        Section("Verified backup browser") {
            Button("Refresh & Verify Backups") { Task { await manager.refresh() } }.disabled(manager.busy)
            ForEach(manager.backups) { backup in
                HStack {
                    VStack(alignment: .leading) {
                        Text(backup.date.formatted())
                        Text("\(backup.notes) notes · \(backup.notebooks) notebooks")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recover Copies…") { restoring = backup }.disabled(manager.busy)
                }
            }
            Text("Recovery adds all notes and notebooks as new copies, including backed-up Trash. It never replaces your current library. Repeating recovery creates additional copies. Backups are verified again immediately before import.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Recover this backup as copies?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }
        ), titleVisibility: .visible) {
            Button("Add Recovered Copies") {
                if let restoring { Task { await manager.restore(restoring) } }
                restoring = nil
            }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let restoring {
                Text("\(restoring.date.formatted()): \(restoring.notes) notes in \(restoring.notebooks) notebooks. Existing notes stay unchanged.")
            }
        }
        .task { await manager.refresh() }
    }
}
