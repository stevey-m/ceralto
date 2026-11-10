import NotesCore
import SwiftUI

struct SmartFolderSheet: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    let draft: SmartFolder
    @ViewState private var name: String
    @ViewState private var query: String
    @ViewState private var failure: String?

    init(draft: SmartFolder) {
        self.draft = draft
        _name = ViewState(initialValue: draft.name)
        _query = ViewState(initialValue: draft.query)
    }

    private var folder: SmartFolder { SmartFolder(id: draft.id, name: name, query: query) }
    private var queryError: String? { NoteQuery(query).errorMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.smartFolders.contains { $0.id == draft.id } ? "Edit Smart Folder" : "New Smart Folder")
                .font(.title2.weight(.semibold))
            Text("A live search across active notes. Notes stay in their original notebooks.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Smart folder name")
            TextField("Search rules", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Smart folder search rules")
            SearchSyntaxHelp()
            if let error = queryError ?? failure {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            } else {
                let count = store.smartFolderCount(folder)
                Text("\(count) matching \(count == 1 ? "note" : "notes")")
                    .foregroundStyle(.secondary)
            }
            Text("Rules are saved on this Mac, separately from your notes. They are not synced or included in library exports. New notes are created in a real notebook, not inside a smart folder.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.saveSmartFolder(folder); dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || queryError != nil)
            }
        }
        .padding(24).frame(width: 560)
        .background(.background)
        .folioAppearance()
        .onChange(of: name) { _, _ in failure = nil }
        .onChange(of: query) { _, _ in failure = nil }
    }
}

struct SearchSyntaxHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search titles, text, tags and notebook names. All terms must match.")
            Text(#"tag:work notebook:"Work/Projects" title:"Release plan" is:pinned"#)
                .font(.callout.monospaced()).textSelection(.enabled)
            Text(#"Use "quoted phrases" and -tag:archive to exclude a term or filter. Notebook filters include subtopics. Tags match exactly."#)
            Text("updated-after:2026-01-01 includes that date; updated-before:2027-01-01 excludes that date. Dates use midnight UTC.")
            Text("No OR, wildcards, regular expressions or attachment-content search. Unknown prefixes, such as https:, are ordinary text.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
