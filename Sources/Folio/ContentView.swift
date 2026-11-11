import NotesCore
import SwiftUI

// Select the property wrapper, not the SDK's same-named State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var noteToDelete: Note?
    @ViewState private var notebookToDelete: Notebook?
    @ViewState private var pendingCommand: FolioCommand?
    @ViewState private var smartFolderToDelete: SmartFolder?
    @ViewState private var showingSearchHelp = false
    @ViewState private var selectedNoteIDs: Set<UUID> = []
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("showNotebookPane") private var showNotebooks = true
    @AppStorage("showNoteListPane") private var showNotes = true
    @ViewState private var collapsedBranches: Set<String> = []
    @ViewState private var collapsedNotebookBranches: Set<String> = []
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NotebookLayout(showNotebooks: showNotebooks, showNotes: showNotes) {
            sidebar
        } notes: {
            noteList
        } document: {
            ReferenceLayout(showReference: store.referenceNote != nil) {
                detail
            } reference: {
                if let note = store.referenceNote {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reference · Read only").font(.caption).foregroundStyle(.secondary)
                                Text(note.displayTitle).font(.headline).lineLimit(1)
                            }
                            Spacer()
                            Button { store.showReference(nil) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Close reference pane")
                        }.padding(14)
                        Divider()
                        MarkdownPreview(note: note).id(note.id)
                    }
                }
            }
        }
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.background : Color(nsColor: .windowBackgroundColor))
        .folioAppearance()
        .foregroundStyle(theme == FolioTheme.dracula.rawValue ? FolioPalette.foreground : Color.primary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: store.navigateBack) { Image(systemName: "chevron.left") }
                    .help("Back (\(store.shortcut(.back).label))").accessibilityLabel("Back")
                    .disabled(!store.workspace.canGoBack)
                Button(action: store.navigateForward) { Image(systemName: "chevron.right") }
                    .help("Forward (\(store.shortcut(.forward).label))").accessibilityLabel("Forward")
                    .disabled(!store.workspace.canGoForward)
                Button { showNotebooks.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Toggle notebooks (\(store.shortcut(.toggleFolders).label))")
                    .accessibilityLabel("Toggle notebooks")
                Button { showNotes.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Toggle note list (\(store.shortcut(.toggleNotes).label))")
                    .accessibilityLabel("Toggle note list")
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
                Button { store.showingFinder = true } label: { Image(systemName: "text.magnifyingglass") }
                    .help("Find across all notes (\(store.shortcut(.find).label))")
                    .accessibilityLabel("Find across all notes")
                Button { store.showingCommands = true } label: { Image(systemName: "command") }
                    .help("Command palette (\(store.shortcut(.palette).label))")
                    .accessibilityLabel("Command palette")
                Button { openWindow(id: "capture") } label: { Image(systemName: "tray.and.arrow.down") }
                    .help("Quick capture")
                    .accessibilityLabel("Quick capture")
            }
        }
        .navigationTitle("Deltos")
        .onChange(of: store.scope) { _, _ in
            store.reconcileSelection()
            revealSelectedNotebook()
        }
        .onAppear {
            revealSelectedNotebook()
            if let id = store.selectedNoteID { selectedNoteIDs = [id] }
        }
        .onChange(of: store.query) { _, _ in store.reconcileSelection() }
        .sheet(item: $store.notebookDraft) { draft in
            NotebookSheet(draft: draft)
        }
        .sheet(item: $store.smartFolderDraft) { draft in
            SmartFolderSheet(draft: draft).environmentObject(store)
        }
        .sheet(isPresented: $store.showingFinder) {
            NoteFinder().environmentObject(store)
        }
        .sheet(isPresented: $store.showingTemplates) {
            TemplateChooser().environmentObject(store)
        }
        .sheet(isPresented: $store.showingTasks) {
            TaskOverview().environmentObject(store)
        }
        .sheet(isPresented: $store.showingCommands, onDismiss: {
            if let command = pendingCommand {
                pendingCommand = nil
                store.perform(command)
            }
        }) {
            CommandPalette(onSelect: { pendingCommand = $0 }).environmentObject(store)
        }
        .alert("Deltos", isPresented: Binding(
            get: { store.importSummary != nil },
            set: { if !$0 { store.importSummary = nil } }
        )) {
            if let report = store.importReportURL {
                Button("Show Import Report") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importSummary ?? "")
        }
        .alert("Deltos needs your attention", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            if store.hasUnsavedChanges || !store.isLoaded {
                Button(store.isLoaded ? "Retry Saving" : "Retry Opening") {
                    if store.isLoaded { store.save() } else { store.load() }
                }
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
        .confirmationDialog("Delete this smart folder?", isPresented: Binding(
            get: { smartFolderToDelete != nil },
            set: { if !$0 { smartFolderToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Smart Folder", role: .destructive) {
                if let folder = smartFolderToDelete { store.deleteSmartFolder(folder.id) }
                smartFolderToDelete = nil
            }
        } message: {
            Text("Only the saved search is removed. No notes or notebooks will be deleted.")
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if !store.workspace.tabs.isEmpty {
                documentTabs
                Divider()
            }
            ZStack {
                ForEach(store.workspace.tabs, id: \.self) { id in
                    if let note = store.library.notes.first(where: { $0.id == id }) {
                        let active = store.selectedNoteID == id
                        NoteEditor(note: note, onPermanentDelete: { noteToDelete = note }, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .disabled(!active || !store.isLoaded)
                            .zIndex(active ? 1 : 0)
                    }
                }
                if store.selectedNote == nil {
                    ContentUnavailableView {
                        Label(store.isLoaded ? "Room for a new thought" : "Your library is unavailable",
                              systemImage: store.isLoaded ? "square.and.pencil" : "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(store.isLoaded
                             ? "Select a note, or create something new."
                             : "Retry opening your library. Deltos will not overwrite a file it cannot read.")
                    } actions: {
                        if store.isLoaded {
                            Button("New Note", action: store.createNote)
                        } else {
                            Button("Retry Opening Library", action: store.load)
                        }
                    }
                    .zIndex(2)
                }
            }
        }
    }

    private var documentTabs: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(store.workspace.tabs, id: \.self) { id in
                    if let note = store.library.notes.first(where: { $0.id == id }) {
                        HStack(spacing: 8) {
                            Button { store.openNote(id) } label: {
                                Text(note.displayTitle).lineLimit(1).frame(maxWidth: 170)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .help(note.displayTitle)
                            .accessibilityAddTraits(store.selectedNoteID == id ? .isSelected : [])
                            Button { store.closeTab(id) } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Close \(note.displayTitle)")
                        }
                        .padding(.horizontal, 10)
                        .background(store.selectedNoteID == id ? (theme == FolioTheme.dracula.rawValue ? FolioPalette.selection : Color.accentColor.opacity(0.13)) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .id(id)
                    }
                }
            }.padding(6)
        }
        .scrollIndicators(.hidden)
        .frame(height: 42)
        .onChange(of: store.selectedNoteID) { _, id in
            if let id { proxy.scrollTo(id) }
        }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deltos").font(.title2.weight(.semibold))
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
                if BuiltInFeature.allCases.contains(where: store.featureEnabled) {
                    Section("Workspace") {
                        if store.featureEnabled(.dailyNotes) {
                            Button { store.perform(.today) } label: { Label("Today's Note", systemImage: "calendar") }
                                .buttonStyle(.plain).disabled(!store.isLoaded)
                        }
                        if store.featureEnabled(.templates) {
                            Button { store.perform(.templates) } label: { Label("Templates", systemImage: "doc.on.doc") }
                                .buttonStyle(.plain).disabled(!store.isLoaded)
                        }
                        if store.featureEnabled(.tasks) {
                            Button { store.perform(.tasks) } label: { Label("Tasks", systemImage: "checklist") }
                                .buttonStyle(.plain).disabled(!store.isLoaded)
                        }
                    }
                }
                Section {
                    ForEach(store.sidebarNotebooks) { branch in
                        notebookTree(branch)
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
                    Text("Notebooks")
                }
                Section("Smart Folders") {
                    ForEach(store.smartFolders) { folder in
                        HStack {
                            Label(folder.name, systemImage: "folder.badge.gearshape")
                                .lineLimit(1).help(folder.query)
                            Spacer()
                            Text("\(store.smartFolderCount(folder))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(NoteScope.smart(folder.id))
                        .folioListRow(selected: store.mainFolderScope == .smart(folder.id))
                        .contextMenu {
                            Button("Edit Smart Folder...") { store.smartFolderDraft = folder }
                                .disabled(!store.smartFoldersAvailable)
                            Button("Delete Smart Folder...", role: .destructive) { smartFolderToDelete = folder }
                                .disabled(!store.smartFoldersAvailable)
                        }
                    }
                    Button(action: store.draftSmartFolder) {
                        Label("New Smart Folder", systemImage: "plus").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(FolioCommand.newSmartFolder.unavailableReason(in: store) != nil)
                    if !store.smartFoldersAvailable {
                        Button("Reload Smart Folders", action: store.reloadSmartFolders)
                        Text("Saved rules unavailable").font(.caption).foregroundStyle(.orange)
                    }
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
                    Button("Connect Cloud Folder...", action: store.chooseSyncFolder)
                        .disabled(store.isSyncing)
                    Button("Sync Now", action: store.syncNow)
                        .disabled(store.syncFolderName == nil || store.isSyncing)
                    Button("Disconnect", action: store.disconnectSyncFolder)
                        .disabled(store.syncFolderName == nil || store.isSyncing)
                } label: {
                    Label(store.isSyncing ? "Exchanging snapshots..." : store.syncFolderName ?? "Connect Cloud Folder",
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
        .foregroundStyle(theme == FolioTheme.dracula.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private func revealSelectedNotebook() {
        guard let path = store.navigationFolder?.id else { return }
        collapsedNotebookBranches = collapsedNotebookBranches.filter { !path.hasPrefix($0 + "/") }
    }

    private func notebookTree(_ branch: NotebookBranch) -> AnyView {
        let scope = NoteScope.folder(branch.id, branch.descendants)
        return AnyView(Group {
            if branch.children.isEmpty {
                scopeRow(branch.name, icon: "folder", scope: scope)
                    .draggable("deltos-folder:" + branch.id)
                    .dropDestination(for: String.self) { items, _ in store.acceptNotebookDrop(items, on: branch.id) }
                    .help(branch.id)
                    .contextMenu { notebookActions(branch) }
            } else {
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsedNotebookBranches.contains(branch.id) },
                    set: { if $0 { collapsedNotebookBranches.remove(branch.id) } else { collapsedNotebookBranches.insert(branch.id) } }
                )) {
                    ForEach(branch.children) { child in notebookTree(child) }
                } label: {
                    scopeRow(branch.name, icon: "folder", scope: scope).help(branch.id)
                        .draggable("deltos-folder:" + branch.id)
                        .dropDestination(for: String.self) { items, _ in store.acceptNotebookDrop(items, on: branch.id) }
                }
                .tag(scope)
                .folioListRow(selected: store.mainFolderScope == scope)
                .contextMenu { notebookActions(branch) }
            }
        })
    }

    @ViewBuilder private func notebookActions(_ branch: NotebookBranch) -> some View {
        Button("Rename or Move Branch...") {
            store.notebookDraft = NotebookDraft(name: branch.id, branchPath: branch.id)
        }
        Button("New Subfolder...") {
            store.notebookDraft = NotebookDraft(name: branch.id + "/")
        }
        ForEach(branch.notebooks) { notebook in
            if branch.notebooks.count > 1 {
                Button("Rename Duplicate \(notebook.id.uuidString.prefix(8))...") {
                    store.notebookDraft = NotebookDraft(existingID: notebook.id, name: notebook.name)
                }
            }
            Button("New Note in \(notebook.name)") {
                store.scope = .notebook(notebook.id)
                store.selectedNoteID = nil
                store.createNote()
            }
            Button("Delete \(notebook.name)...", role: .destructive) { notebookToDelete = notebook }
                .disabled(store.library.notebooks.count < 2)
        }
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
                                Button("Rename or Move Branch...") {
                                    store.notebookDraft = NotebookDraft(name: branch.id, branchPath: branch.id)
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
            .folioListRow(selected: selectedNoteIDs.contains(note.id))
            .draggable("deltos-note:" + note.id.uuidString)
            .contextMenu {
                if selectedNoteIDs.count > 1, selectedNoteIDs.contains(note.id) {
                    bulkActions(selectedNoteIDs)
                } else {
                    Button("Open in New Tab") { store.openNoteInNewTab(note.id) }
                    Button("Show as Reference") { store.showReference(note.id) }
                    Divider()
                    if note.deletedAt != nil {
                        Button("Restore Note") { store.restore(note.id) }
                        Button("Delete Forever...", role: .destructive) { noteToDelete = note }
                    } else {
                        Menu("Move to Notebook") {
                            ForEach(store.library.notebooks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { notebook in
                                Button(notebook.name) { store.moveNotes([note.id], to: notebook.name) }
                                    .disabled(notebook.id == note.notebookID)
                            }
                        }
                        Button(note.isPinned ? "Unpin Note" : "Pin Note") {
                            store.update(note.id) { $0.isPinned.toggle() }
                        }
                        Button("Export Markdown...") { store.exportMarkdown(note) }
                        Button("Move to Trash", role: .destructive) { store.trash(note.id) }
                    }
                }
            }
    }

    private func scopeRow(_ title: String, icon: String, scope: NoteScope) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .lineLimit(1)
            Spacer()
            Text("\(store.noteCount(in: scope))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .tag(scope)
        .folioListRow(selected: store.mainFolderScope == scope)
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
            if let folder = store.activeSmartFolder {
                HStack(alignment: .top) {
                    Text(folder.query).font(.caption.monospaced()).lineLimit(3).help(folder.query)
                    Spacer()
                    Button { store.smartFolderDraft = folder } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).accessibilityLabel("Edit smart folder rules")
                        .disabled(!store.smartFoldersAvailable)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            HStack {
                Button("Search Help") { showingSearchHelp.toggle() }
                    .popover(isPresented: $showingSearchHelp) {
                        SearchSyntaxHelp().padding(20).frame(width: 440).folioAppearance()
                    }
                Spacer()
                Button("Save Search...", action: store.draftSmartFolder)
                    .disabled(!store.isLoaded || !store.smartFoldersAvailable || store.scope == .trash ||
                              store.searchError != nil)
            }
            .font(.caption).buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.bottom, 10)
            if let error = store.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            List(selection: noteSelection) {
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
                if let id {
                    if !selectedNoteIDs.contains(id) { selectedNoteIDs = [id] }
                } else { selectedNoteIDs = [] }
                guard let id, let note = store.outlineNotes.first(where: { $0.id == id }) else { return }
                if let folder = store.navigationFolder {
                    let path = store.library.notebooks.first { $0.id == note.notebookID }?.name ?? folder.id
                    collapsedBranches = collapsedBranches.filter { !(path == $0 || path.hasPrefix($0 + "/")) }
                }
            }
            .onChange(of: store.outlineNotes.map(\.id)) { _, ids in
                selectedNoteIDs.formIntersection(Set(ids))
                if selectedNoteIDs.isEmpty, let id = store.selectedNoteID, ids.contains(id) { selectedNoteIDs = [id] }
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
                    Button("Joplin JEX Archive...", action: store.importJoplinArchive)
                        .disabled(store.isImportingJoplin || store.isSyncing)
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
                Menu {
                    noteOrderingControls
                } label: {
                    Label(store.noteOrdering.field.rawValue, systemImage: store.noteOrdering.ascending ? "arrow.up" : "arrow.down")
                }.menuStyle(.borderlessButton).fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedNoteIDs.count > 1 {
                HStack {
                    Text("\(selectedNoteIDs.count) selected").font(.caption)
                    Spacer()
                    Menu("Actions") { bulkActions(selectedNoteIDs) }.menuStyle(.borderlessButton)
                }
                .padding(12)
                .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.sidebar : Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.background : Color(nsColor: .controlBackgroundColor))
    }

    private var noteSelection: Binding<Set<UUID>> {
        Binding(get: { selectedNoteIDs }, set: { ids in
            let added = ids.subtracting(selectedNoteIDs)
            selectedNoteIDs = ids
            if added.isEmpty, let primary = store.selectedNoteID, ids.contains(primary) { return }
            let ordered = store.outlineNotes
            if let note = ordered.first(where: { added.contains($0.id) }) ??
                ordered.first(where: { ids.contains($0.id) }) {
                store.selectedNoteID = note.id
            } else { store.selectedNoteID = nil }
        })
    }

    @ViewBuilder private var noteOrderingControls: some View {
        Picker("Sort notes by", selection: Binding(
            get: { store.noteOrdering.field },
            set: { store.setNoteOrdering(NoteOrdering(field: $0, ascending: store.noteOrdering.ascending)) }
        )) {
            ForEach(NoteSortField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Toggle("Ascending", isOn: Binding(
            get: { store.noteOrdering.ascending },
            set: { store.setNoteOrdering(NoteOrdering(field: store.noteOrdering.field, ascending: $0)) }
        ))
        Text("Pinned notes stay first")
    }

    @ViewBuilder private func bulkActions(_ ids: Set<UUID>) -> some View {
        let busy = store.isReadOnly || store.isSyncing || store.isImportingJoplin || store.isProcessingEncryptedBackup
        if store.scope == .trash {
            Button("Restore \(ids.count) Notes") { store.runBulkAction(.restore, ids: ids) }.disabled(busy)
        } else {
            Menu("Move \(ids.count) Notes to Notebook") {
                ForEach(store.library.notebooks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { notebook in
                    Button(notebook.name) { store.runBulkAction(.move(notebook.id), ids: ids) }
                }
            }.disabled(busy)
            Button("Add Tags to \(ids.count) Notes...") { store.addTagsToNotes(ids) }.disabled(busy)
            Button("Move \(ids.count) Notes to Trash...", role: .destructive) { store.confirmBulkTrash(ids) }.disabled(busy)
        }
        Button("Export \(ids.count) Selected Notes...") { store.exportSelectedNotes(ids) }
            .disabled(store.isSyncing || store.isImportingJoplin || store.isProcessingEncryptedBackup)
    }
}

private struct NoteRow: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @AppStorage("noteListPreviewLines") private var previewLines = 2
    @AppStorage("noteListShowDates") private var showDates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.displayTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
            }
            if previewLines > 0 {
                Text(note.body.isEmpty ? "No additional text" : store.textSummary(for: note).excerpt)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(min(previewLines, 3))
            }
            if showDates || !note.tags.isEmpty {
                HStack {
                    if showDates { Text(note.updatedAt, format: .dateTime.month(.abbreviated).day()) }
                    Spacer()
                    if let tag = note.tags.first { Text("#\(tag)").lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
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
            Text(draft.branchPath != nil ? "Rename or move notebook branch" : draft.existingID == nil ? "New notebook" : "Rename notebook")
                .font(.title2.weight(.semibold))
            TextField("Notebook name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if draft.branchPath != nil {
                Text("Enter the full destination path, for example Work/Research. All subfolders move together. Use a single name to move to the top level. Existing branches are never merged. Notebook-qualified text links are not rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.branchPath != nil ? "Apply" : draft.existingID == nil ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .folioAppearance()
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let path = draft.branchPath {
            guard store.renameNotebookBranch(path, to: name) else { return }
        } else if let id = draft.existingID {
            guard store.renameNotebook(id, name: name) else { return }
        }
        else { guard store.addNotebook(name: name) else { return } }
        dismiss()
    }
}
