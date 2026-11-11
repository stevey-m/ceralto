import AppKit
import NotesCore
import SwiftUI

@MainActor
enum BackupPasswordPrompt {
    static func request(exporting: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = exporting ? "Encrypt Complete Backup" : "Unlock Encrypted Backup"
        alert.informativeText = exporting
            ? "Use at least 12 characters. Deltos never stores this password and cannot recover it. Keep it somewhere safe, separately from the backup."
            : "Enter this backup's password. Import adds copies; it does not replace existing notes. The restored notes and attachments will be unencrypted in your local library."
        alert.addButton(withTitle: exporting ? "Encrypt Backup" : "Unlock & Import")
        alert.addButton(withTitle: "Cancel")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: exporting ? 38 : 0, width: 360, height: 24))
        password.placeholderString = "Password"
        password.setAccessibilityLabel("Backup password")
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        confirmation.placeholderString = "Confirm password"
        confirmation.setAccessibilityLabel("Confirm backup password")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: exporting ? 66 : 28))
        accessory.addSubview(password)
        if exporting { accessory.addSubview(confirmation) }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = password
        defer { password.stringValue = ""; confirmation.stringValue = "" }
        while alert.runModal() == .alertFirstButtonReturn {
            let value = password.stringValue
            if value.isEmpty || value.utf8.count > 1_024 || (exporting && value.count < 12) {
                alert.informativeText = "Enter \(exporting ? "at least 12 characters and " : "")no more than 1,024 UTF-8 bytes. Deltos never stores this password."
            } else if exporting && value != confirmation.stringValue {
                alert.informativeText = "The passwords do not match. Enter the same password in both fields."
            } else {
                return value
            }
        }
        return nil
    }
}

struct HistoryPolicyControls: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var draft = HistoryPolicy.standard
    @ViewState private var confirmingPruning = false

    var body: some View {
        Section("Note history") {
            Toggle("Capture checkpoints automatically", isOn: $draft.enabled)
            Picker("Checkpoint interval", selection: $draft.intervalSeconds) {
                ForEach(HistoryPolicy.intervals, id: \.self) { seconds in
                    Text("\(seconds / 60) minute(s)").tag(seconds)
                }
            }
            Picker("Checkpoints per note", selection: $draft.maximumCheckpoints) {
                ForEach(HistoryPolicy.counts, id: \.self) { Text("\($0)").tag($0) }
            }
            Button(store.historyPolicyAvailable ? "Apply History Settings" : "Replace Unreadable History Settings...") {
                if store.historyPruningCount(for: draft) > 0 { confirmingPruning = true }
                else { apply(confirmed: false) }
            }
            Text(store.historyPolicy.summary).font(.caption).foregroundStyle(.secondary)
            Text("Pausing capture keeps existing history. Lowering retention can permanently remove older checkpoints, including those in Trash; confirmation is required. Restoring a version always saves your current text first, even when automatic capture is paused. Backups and sync snapshots may retain older copies.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!store.isLoaded || store.isReadOnly || store.isSyncing || store.isImportingJoplin || store.isProcessingEncryptedBackup)
        .onAppear { draft = store.historyPolicy }
        .confirmationDialog("Remove older note-history checkpoints?", isPresented: $confirmingPruning, titleVisibility: .visible) {
            Button("Remove \(store.historyPruningCount(for: draft)) Checkpoints", role: .destructive) { apply(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the oldest checkpoints beyond \(draft.maximumCheckpoints) per note from this library. Current notes and independent backups are not deleted.")
        }
    }

    private func apply(confirmed: Bool) {
        do { try store.applyHistoryPolicy(draft, confirmedPruning: confirmed) }
        catch { store.errorMessage = "Could not apply note-history settings: \(error.localizedDescription)" }
    }
}
