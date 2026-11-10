import NotesCore
import SwiftUI

struct LinkedMentionsView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    let note: Note
    @ViewState private var mentions: [Note] = []
    @ViewState private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Linked mentions").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Notes that refer to \(note.displayTitle) using [[note links]].")
                .font(.callout).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.orange) }
            else if mentions.isEmpty {
                ContentUnavailableView("No linked mentions yet", systemImage: "link",
                    description: Text("Use [[\(note.displayTitle)]] in another note to connect them."))
            } else {
                List(mentions) { linked in
                    Button {
                        store.openNote(linked.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(linked.displayTitle).font(.headline)
                            Text(store.textSummary(for: linked).excerpt).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(22).frame(width: 520, height: 400)
        .folioAppearance()
        .task(id: store.library) {
            do { mentions = try NoteLinks.backlinks(to: note, in: store.library) }
            catch { failure = "Could not read linked mentions: \(error.localizedDescription)" }
        }
    }
}
