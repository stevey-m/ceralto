import NotesCore
import SwiftUI

// Select the property wrapper, not the SDK's same-named State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var noteToDelete: Note?
    @ViewState private var notebookToDelete: Notebook?
    @AppStorage("folioTheme") private var theme = FolioTheme.dracula.rawValue
    @AppStorage("showNotebookPane") private var showNotebooks = true
    @AppStorage("showNoteListPane") private var showNotes = true
    @ViewState private var collapsedBranches: Set<String> = []
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NotebookLayout(showNotebooks: showNotebooks, showNotes: showNotes) {
            sidebar
        } notes: {
            noteList
        } document: {
            detail
        }
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.background : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(theme == FolioTheme.dracula.rawValue ? .dark : nil)
        .foregroundStyle(theme == FolioTheme.dracula.rawValue ? FolioPalette.foreground : Color.primary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { showNotebooks.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Toggle notebooks (Command-Option-S)")
                    .accessibilityLabel("Toggle notebooks")
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button { showNotes.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Toggle note list (Command-Option-L)")
                    .accessibilityLabel("Toggle note list")
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button {
                    let focused = !showNotebooks && !showNotes
                    showNotebooks = focused
                    showNotes = focused
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Toggle focused writing")
                    .accessibilityLabel("Toggle focused writing")
                Button { showNotes = true; searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .help("Find notes (Command-F)")
                    .accessibilityLabel("Find notes")
                    .keyboardShortcut("f")
                Button { store.showingFinder = true } label: { Image(systemName: "command") }
                    .help("Find across all notes (Command-K)")
                    .accessibilityLabel("Find across all notes")
                Button { openWindow(id: "capture") } label: { Image(systemName: "tray.and.arrow.down") }
                    .help("Quick capture")
                    .accessibilityLabel("Quick capture")
            }
        }
        .navigationTitle("Folio")
        .tint(theme == FolioTheme.dracula.rawValue ? FolioPalette.purple : .indigo)
        .onChange(of: store.scope) { _, _ in store.reconcileSelection() }
        .onChange(of: store.query) { _, _ in store.reconcileSelection() }
        .sheet(item: $store.notebookDraft) { draft in
            NotebookSheet(draft: draft)
        }
        .sheet(isPresented: $store.showingFinder) {
            NoteFinder().environmentObject(store)
        }
        .alert("Import complete", isPresented: Binding(
            get: { store.importSummary != nil },
            set: { if !$0 { store.importSummary = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importSummary ?? "")
        }
        .alert("Folio needs your attention", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(store.isLoaded ? "Retry Saving" : "Retry Opening") {
                if store.isLoaded { store.save() } else { store.load() }
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog("Permanently delete this note?", isPresented: Binding(
            get: { noteToDelete != nil },
            set: { if !$0 { noteToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) {
                if let noteToDelete { store.permanentlyDelete(noteToDelete.id) }
                noteToDelete = nil
            }
        } message: {
            Text("This removes the note from your current library. Existing backups and shared sync snapshots retain their earlier copies. Export the note first if you want to keep a copy.")
        }
        .confirmationDialog("Delete this notebook?", isPresented: Binding(
            get: { notebookToDelete != nil },
            set: { if !$0 { notebookToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Notebook", role: .destructive) {
                if let notebookToDelete { store.deleteNotebook(notebookToDelete.id) }
                notebookToDelete = nil
            }
        } message: {
            Text("Its notes, including notes in Trash, will move to the first remaining notebook. No notes will be deleted.")
        }
    }

    @ViewBuilder private var detail: some View {
            if let note = store.selectedNote {
                NoteEditor(note: note, onPermanentDelete: { noteToDelete = note })
                    .id(note.id)
            } else {
                ContentUnavailableView {
                    Label(store.isLoaded ? "Room for a new thought" : "Your library is unavailable",
                          systemImage: store.isLoaded ? "square.and.pencil" : "externaldrive.badge.exclamationmark")
                } description: {
                    Text(store.isLoaded
                         ? "Select a note, or create something new."
                         : "Retry opening your library. Folio will not overwrite a file it cannot read.")
                } actions: {
                    if store.isLoaded {
                        Button("New Note", action: store.createNote)
                    } else {
                        Button("Retry Opening Library", action: store.load)
                    }
                }
            }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(theme == FolioTheme.dracula.rawValue ? FolioPalette.purple : .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folio").font(.title2.weight(.semibold))
                    Text("Your offline library")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            List(selection: $store.mainFolderScope) {
                Section("Library") {
                    scopeRow("All Notes", icon: "tray.full", scope: .all)
                    if let inbox = store.inboxID {
                        scopeRow("Inbox", icon: "tray", scope: .notebook(inbox))
                    }
                    scopeRow("Pinned", icon: "pin", scope: .pinned)
                    scopeRow("Trash", icon: "trash", scope: .trash)
                }
                Section {
                    ForEach(NotebookBranch.build(store.library.notebooks.filter { $0.id != store.inboxID })) { branch in
                        scopeRow(branch.name, icon: "folder", scope: .folder(branch.id, branch.descendants))
                            .contextMenu {
                                Button("New Subtopic...") {
                                    store.notebookDraft = NotebookDraft(name: branch.id + "/")
                                }
                                ForEach(branch.notebooks) { notebook in
                                    Button("Rename \(notebook.name)...") {
                                        store.notebookDraft = NotebookDraft(existingID: notebook.id, name: notebook.name)
                                    }
                                    Button("Delete \(notebook.name)...", role: .destructive) { notebookToDelete = notebook }
                                        .disabled(store.library.notebooks.count < 2)
                                }
                            }
                    }
                    Button {
                        store.notebookDraft = NotebookDraft()
                    } label: {
                        Label("New Notebook", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.isLoaded)
                } header: {
                    Text("Main Folders")
                }
                if !store.tags.isEmpty {
                    Section("Tags") {
                        ForEach(store.tags, id: \.self) { tag in
                            scopeRow(tag, icon: "number", scope: .tag(tag))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Menu {
                    Text(store.syncMessage)
                    Button("Connect iCloud Drive Folder...", action: store.chooseSyncFolder)
                        .disabled(store.isSyncing)
                    Button("Sync Now", action: store.syncNow)
                        .disabled(store.syncFolderName == nil || store.isSyncing)
                    Button("Disconnect", action: store.disconnectSyncFolder)
                        .disabled(store.syncFolderName == nil || store.isSyncing)
                } label: {
                    Label(store.isSyncing ? "Syncing..." : store.syncFolderName ?? "Connect iCloud Drive",
                          systemImage: store.isSyncing ? "arrow.triangle.2.circlepath" : "icloud")
                }
                .menuStyle(.borderlessButton)
                Text(store.syncMessage).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3).help(store.syncMessage)
            }.padding(.horizontal, 14).padding(.top, 12)
            HStack(spacing: 6) {
                Image(systemName: store.hasUnsavedChanges ? "exclamationmark.icloud" : "internaldrive")
                Text(store.hasUnsavedChanges ? "Changes not saved" : "Stored on this Mac")
                Spacer()
                Button(action: store.revealLibrary) { Image(systemName: "folder") }
                    .buttonStyle(.plain)
                    .help("Show library in Finder")
                    .accessibilityLabel("Show library in Finder")
            }
            .font(.caption)
            .foregroundStyle(store.hasUnsavedChanges ? .orange : .secondary)
            .padding(14)
        }
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.sidebar : Color(nsColor: .windowBackgroundColor))
    }

    private func topicView(_ branch: NotebookBranch) -> AnyView {
        let notes = store.outlineNotes
        return AnyView(Group {
            if store.query.isEmpty || notes.contains(where: { branch.descendants.contains($0.notebookID) }) {
                DisclosureGroup(isExpanded: Binding(
                    get: { !store.query.isEmpty || !collapsedBranches.contains(branch.id) },
                    set: { if $0 { collapsedBranches.remove(branch.id) } else { collapsedBranches.insert(branch.id) } }
                )) {
                    ForEach(notes.filter { note in branch.notebooks.contains { $0.id == note.notebookID } }) { note in
                        noteRow(note)
                    }
                    ForEach(branch.children) { child in topicView(child) }
                } label: {
                    Label(branch.name, systemImage: "folder")
                        .font(.headline).lineLimit(1).help(branch.id)
                        .contextMenu {
                            Button("New Subtopic...") {
                                store.notebookDraft = NotebookDraft(name: branch.id + "/")
                            }
                            ForEach(branch.notebooks) { notebook in
                                Button("New Note in \(notebook.name)") {
                                    store.scope = .notebook(notebook.id)
                                    store.selectedNoteID = nil
                                    store.createNote()
                                }
                                Button("Rename \(notebook.name)...") {
                                    store.notebookDraft = NotebookDraft(existingID: notebook.id, name: notebook.name)
                                }
                                Button("Delete \(notebook.name)...", role: .destructive) { notebookToDelete = notebook }
                                    .disabled(store.library.notebooks.count < 2)
                            }
                        }
                }
            }
        })
    }

    private func noteRow(_ note: Note) -> some View {
        NoteRow(note: note)
            .tag(note.id)
            .contextMenu {
                if note.deletedAt != nil {
                    Button("Restore Note") { store.restore(note.id) }
                    Button("Delete Forever...", role: .destructive) { noteToDelete = note }
                } else {
                    Button(note.isPinned ? "Unpin Note" : "Pin Note") {
                        store.update(note.id) { $0.isPinned.toggle() }
                    }
                    Button("Export Markdown...") { store.exportMarkdown(note) }
                    Button("Move to Trash", role: .destructive) { store.trash(note.id) }
                }
            }
    }

    private func scopeRow(_ title: String, icon: String, scope: NoteScope) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .lineLimit(1)
            Spacer()
            Text("\(store.library.notes.filter { scope.includes($0) }.count)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .tag(scope)
        .padding(.vertical, 3)
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.navigationFolder?.name ?? store.scopeTitle).font(.title2.weight(.semibold)).lineLimit(1)
                    Text("\(store.outlineNotes.count) \(store.outlineNotes.count == 1 ? "note" : "notes")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.createNote) {
                    Image(systemName: "square.and.pencil").font(.title3)
                }
                .buttonStyle(.borderless)
                .help("New Note (Command-N)")
                .accessibilityLabel("New note")
                .disabled(!store.isLoaded)
            }
            .padding(18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $store.query).textFieldStyle(.plain)
                    .focused($searchFocused)
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            List(selection: $store.selectedNoteID) {
                if let folder = store.navigationFolder {
                    ForEach(store.outlineNotes.filter { note in folder.notebooks.contains { $0.id == note.notebookID } }) { note in
                        noteRow(note)
                    }
                    ForEach(folder.children) { branch in topicView(branch) }
                } else {
                    ForEach(store.visibleNotes) { note in
                        noteRow(note)
                    }
                }
            }
            .onChange(of: store.selectedNoteID) { _, id in
                guard let id, let note = store.outlineNotes.first(where: { $0.id == id }) else { return }
                if let folder = store.navigationFolder {
                    let path = store.library.notebooks.first { $0.id == note.notebookID }?.name ?? folder.id
                    collapsedBranches = collapsedBranches.filter { !(path == $0 || path.hasPrefix($0 + "/")) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if store.outlineNotes.isEmpty && (store.navigationFolder?.children.isEmpty != false || !store.query.isEmpty) {
                    ContentUnavailableView(
                        store.query.isEmpty ? "No notes here yet" : "No matching notes",
                        systemImage: store.query.isEmpty ? "note.text" : "magnifyingglass",
                        description: Text(store.query.isEmpty ? "New ideas start with a blank page." : "Try another search.")
                    )
                }
            }
            Divider()
            HStack {
                Menu {
                    Button("Markdown or HTML Files...", action: store.importMarkdown)
                    Button("Joplin Export Folder...", action: store.importJoplinFolder)
                        .disabled(store.isImportingJoplin)
                    Button("Markdown or HTML Folder...") { store.importJoplinFolder(includeHTML: true) }
                        .disabled(store.isImportingJoplin)
                } label: {
                    Label(store.isImportingJoplin ? "Importing Joplin..." : "Import",
                          systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!store.isLoaded)
                if store.isImportingJoplin { ProgressView().controlSize(.small) }
                Spacer()
                Image(systemName: "arrow.down")
                Text("Last edited")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.background : Color(nsColor: .controlBackgroundColor))
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.displayTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.indigo)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(note.body.isEmpty ? "No additional text" : note.excerpt)
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
                Spacer()
                if let tag = note.tags.first { Text("#\(tag)").lineLimit(1) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct NotebookSheet: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    let draft: NotebookDraft
    @ViewState private var name: String

    init(draft: NotebookDraft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.existingID == nil ? "New notebook" : "Rename notebook")
                .font(.title2.weight(.semibold))
            TextField("Notebook name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.existingID == nil ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id = draft.existingID { store.renameNotebook(id, name: name) }
        else { store.addNotebook(name: name) }
        dismiss()
    }
}
