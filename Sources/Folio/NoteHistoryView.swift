import NotesCore
import SwiftUI

struct NoteHistoryView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    let note: Note
    @ViewState private var selectedID: UUID?
    @ViewState private var confirmingRestore = false

    private var revision: NoteRevision? { note.history?.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Note history").font(.title2.weight(.semibold))
                    Text("Up to 20 checkpoints, captured at most once every five minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HSplitView {
                List(selection: $selectedID) {
                    ForEach((note.history ?? []).reversed()) { revision in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(revision.savedAt, format: .dateTime.month().day().hour().minute().second())
                            Text(revision.title.isEmpty ? "Untitled note" : revision.title).font(.caption).lineLimit(1)
                        }.tag(revision.id)
                    }
                }.frame(minWidth: 200, idealWidth: 230)
                ScrollView {
                    Text(revision?.body ?? "Select a checkpoint")
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.frame(minWidth: 360)
            }
            HStack {
                Text("Restoring also preserves your current text as a checkpoint.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore This Version") { confirmingRestore = true }
                    .disabled(revision == nil)
            }.padding(16)
        }
        .frame(width: 760, height: 520)
        .confirmationDialog("Restore this version?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore Version") {
                if let revision { store.restoreRevision(revision, noteID: note.id) }
                dismiss()
            }
        }
    }
}
