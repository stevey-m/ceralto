import NotesCore
import SwiftUI

struct CloudSyncControls: View {
    @EnvironmentObject private var store: NotesStore
    @ObservedObject var manager: SyncManager
    @ViewState private var showingConflicts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Connected folder", value: store.syncFolderName ?? "Not connected")
            LabeledContent("Local exchange state", value: manager.status.rawValue)
            Text(manager.message).textSelection(.enabled)
            Text(store.syncMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            LabeledContent("Last successful local exchange",
                           value: manager.schedule.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            LabeledContent("Next attempt", value: nextAttempt)
            Toggle("Schedule local exchange while Ceralto is open", isOn: Binding(
                get: { manager.schedule.enabled },
                set: { manager.configure(enabled: $0) }
            )).disabled(!manager.settingsAvailable)
            Picker("Exchange every", selection: Binding(
                get: { manager.schedule.minutes },
                set: { manager.configure(minutes: $0) }
            )) {
                ForEach(SyncSchedule.intervals, id: \.self) { minutes in
                    Text("\(minutes) minutes").tag(minutes)
                }
            }.disabled(!manager.settingsAvailable || !manager.schedule.enabled)
            Text("Off by default. Missed attempts run after reopening Ceralto; failures retry after five minutes. Manual and scheduled attempts never overlap. This exchanges local snapshots, not verified provider delivery.")
                .font(.caption).foregroundStyle(.secondary)
            if !manager.settingsAvailable {
                Button("Reset sync schedule to manual", action: manager.resetSchedule)
                    .disabled(manager.isRunning)
            }
            HStack {
                Button("Connect Cloud Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing || manager.isRunning)
                Button(manager.isRunning ? "Exchanging..." : "Sync Now", action: store.syncNow)
                    .disabled(store.syncFolderName == nil || manager.isRunning)
                if manager.isRunning {
                    Button("Cancel exchange", action: manager.cancel)
                }
                Button("Disconnect", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil)
            }
            Divider()
            LabeledContent("Conflict variants needing review", value: "\(store.syncConflictNotes.count)")
            ForEach(store.syncConflictSummaries) { summary in
                Text(summary.includesDeletion ?
                     "Edit versus deletion: \(summary.variantIDs.count) edited variant(s) preserved." :
                     "\(summary.variantIDs.count) preserved variant(s): \(titles(for: summary))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Conflicting edits are kept as separate notes tagged #sync-conflict. An edit that conflicts with deletion is also kept. Nothing is discarded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Review preserved conflicts…") { showingConflicts = true }
                .disabled(store.syncConflictNotes.isEmpty)
        }
        .sheet(isPresented: $showingConflicts) {
            SyncConflictReview()
                .environmentObject(store)
        }
    }

    private var nextAttempt: String {
        if !manager.settingsAvailable { return "Schedule unavailable — reset to recover" }
        if store.syncFolderName == nil { return "Connect a folder first" }
        if !manager.schedule.enabled { return "Manual only" }
        if manager.isRunning { return "After the current exchange finishes" }
        return manager.nextAttempt?.formatted(date: .abbreviated, time: .shortened) ?? "Not scheduled"
    }

    private func titles(for summary: SyncConflictSummary) -> String {
        store.syncConflictNotes.filter { summary.variantIDs.contains($0.id) }.map(\.displayTitle).joined(separator: ", ")
    }
}

private struct SyncConflictReview: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ViewState private var confirmingReview = false
    @ViewState private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preserved sync conflicts").font(.title2.bold())
            Text("Compare the preserved variants below or open them to edit. “Keep all” removes only the conflict marker; every note, attachment and history remains. It does not combine text or delete either variant.")
                .foregroundStyle(.secondary)
            List(store.syncConflictNotes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.displayTitle).font(.headline)
                    Text("\(note.deletedAt == nil ? "Preserved note" : "Preserved in Trash") • \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                    Text(note.textContent).lineLimit(8).textSelection(.enabled)
                    Button("Open note to compare or edit") {
                        store.reviewSyncConflict(note.id)
                        openWindow(id: "library")
                        dismiss()
                    }
                }.padding(.vertical, 6)
            }
            if store.syncConflictNotes.isEmpty {
                Text("No unresolved conflict markers. All retained notes remain in your library.")
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button("Keep all variants, mark reviewed…") { confirmingReview = true }
                    .disabled(store.syncConflictNotes.isEmpty || store.isReadOnly || store.isSyncing || store.syncManager.isRunning)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .confirmationDialog("Keep every preserved variant and remove their conflict markers?",
                            isPresented: $confirmingReview, titleVisibility: .visible) {
            Button("Keep all variants and mark reviewed") {
                do {
                    try store.keepSyncConflictVariants(Set(store.syncConflictNotes.map(\.id)))
                    failure = nil
                } catch { failure = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No notes are deleted or combined. Review will be included in the next folder exchange. You can consolidate the notes yourself later.")
        }
    }
}
