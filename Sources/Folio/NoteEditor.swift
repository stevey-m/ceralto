import NotesCore
import SwiftUI

private enum EditorMode: String, CaseIterable {
    case write = "Write", split = "Split", preview = "Preview"
}

struct NoteEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let onPermanentDelete: () -> Void
    var isActive = true
    var searchFocus: FocusState<Bool>.Binding
    @AppStorage("readingEditorMode") private var preferredMode = EditorMode.preview.rawValue
    @ViewState private var mode = EditorMode.preview.rawValue
    @ViewState private var initialized = false
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("showNoteDetails") private var showDetails = false
    @AppStorage("showNotebookPane") private var showNotebooks = true
    @AppStorage("showNoteListPane") private var showNotes = true
    @ViewState private var showingSearch = false
    @ThemeColors private var palette
    @AppStorage("readingFont") private var readingFont = ReadingFont.system.rawValue
    @ViewState private var tagsText = ""
    @FocusState private var tagsFocused: Bool
    @ViewState private var showingHistory = false
    @ViewState private var showingTags = false
    @ViewState private var confirmingSource = false
    @ViewState private var showingBacklinks = false
    @ViewState private var imageURL: URL?
    @StateObject private var formatting = FormattingActions()

    private var isTrashed: Bool { note.deletedAt != nil }
    private var editorMode: EditorMode { EditorMode(rawValue: mode) ?? .preview }

    var body: some View {
        ZStack {
            notePage
                .disabled(imageURL != nil)
                .opacity(imageURL == nil ? 1 : 0)
                .allowsHitTesting(imageURL == nil)
                .accessibilityHidden(imageURL != nil)
            if let imageURL {
                ImageDocumentView(url: imageURL) { self.imageURL = nil }
            }
        }
        .onChange(of: note.id) { _, _ in imageURL = nil }
    }

    private var notePage: some View {
        VStack(spacing: 0) {
            if isActive {
                editorToolbar
                Divider()
            }
            if isTrashed {
                HStack {
                    Label("This note is in Trash", systemImage: "trash")
                    Spacer()
                    Button("Restore") { store.restore(note.id) }
                    Button("Delete Forever...", role: .destructive, action: onPermanentDelete)
                }
                .font(.callout)
                .padding(12)
                .background(.orange.opacity(0.1))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(note.updatedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                if showDetails {
                HStack {
                    Menu {
                        ForEach(store.library.notebooks) { notebook in
                            Button(notebook.name) {
                                store.moveNotes([note.id], to: notebook.name)
                            }
                        }
                    } label: {
                        Label(
                            store.library.notebooks.first { $0.id == note.notebookID }?.name ?? "Notebook",
                            systemImage: "book.closed"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isTrashed)
                    .help("Move to notebook")
                    Spacer()
                    Button { showingTags.toggle() } label: {
                        Label(note.tags.isEmpty ? "Tags" : "\(note.tags.count)", systemImage: "number")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Show or edit tags")
                    .accessibilityLabel("Show or edit tags")
                }
                }
                TextField("Untitled note", text: noteBinding(\.title))
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .semibold))
                    .disabled(isTrashed)
                    .accessibilityLabel("Note title")
                if showingTags {
                    HStack(spacing: 8) {
                        Image(systemName: "number").foregroundStyle(.tertiary)
                        TextField("Add tags, separated by commas", text: $tagsText)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .focused($tagsFocused)
                            .onChange(of: tagsText) { _, text in
                                guard tagsFocused else { return }
                                store.setTags(note.id, text: text)
                            }
                            .onSubmit { tagsFocused = false }
                            .disabled(isTrashed)
                            .accessibilityLabel("Tags, separated by commas")
                    }
                } else if showDetails && !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
            if note.contentFormat == .formatted && editorMode != .preview && !isTrashed {
                FormattedEditor(note: note, fontSize: fontSize,
                                family: ReadingFont(rawValue: readingFont) ?? .system,
                                dracula: palette != nil, actions: formatting) { body in
                    store.update(note.id) { $0.body = body }
                } onError: { store.errorMessage = $0 } onImage: { imageURL = $0 }
                  currentSource: { noteBinding(\.body).wrappedValue }
                  onImportFiles: { try store.importComposeAttachments($0, to: note.id) }
            } else if editorMode == .split && !isTrashed {
                HSplitView {
                    sourceEditor.frame(minWidth: 130)
                    preview.frame(minWidth: 130)
                }
            } else if editorMode == .preview || isTrashed {
                preview
            } else {
                sourceEditor
            }
            if showDetails || store.hasUnsavedChanges {
            Divider()
            HStack(spacing: 14) {
                Label(store.hasUnsavedChanges ? "Not saved" : "Saved locally",
                      systemImage: store.hasUnsavedChanges ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(store.hasUnsavedChanges ? .orange : .secondary)
                Spacer()
                Text("\(store.textSummary(for: note).wordCount) words")
                Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            }
        }
        .background(palette?.backgroundColor ?? Color(nsColor: .textBackgroundColor))
        .onAppear {
            guard !initialized else { return }
            initialized = true
            tagsText = note.tags.joined(separator: ", ")
            mode = preferredMode
            if note.contentFormat == .formatted || (note.body.isEmpty && note.title.isEmpty) {
                mode = EditorMode.write.rawValue
            }
        }
        .onChange(of: mode) { _, value in preferredMode = value }
        .onChange(of: tagsFocused) { _, focused in
            if !focused { tagsText = note.tags.joined(separator: ", ") }
        }
        .onChange(of: searchFocus.wrappedValue) { _, focused in
            if focused && isActive { showingSearch = true }
        }
        .sheet(isPresented: $showingHistory) {
            NoteHistoryView(note: note)
        }
        .sheet(isPresented: $showingBacklinks) {
            LinkedMentionsView(note: note)
        }
        .confirmationDialog("Switch to Markdown source?", isPresented: $confirmingSource, titleVisibility: .visible) {
            Button("Use Source Editor") {
                store.update(note.id) { $0.format = .markdown }
                mode = EditorMode.write.rawValue
            }
        } message: {
            Text("The note is already stored as readable Markdown. Source mode supports advanced Markdown such as tables and nested lists. The note will remain in source mode; its text and attachments will not be converted.")
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 16) {
            if note.contentFormat == .formatted && editorMode == .write {
                NoteFormattingControls(actions: formatting).disabled(isTrashed)
            }
                Button {
                    if note.contentFormat == .formatted && editorMode == .write {
                        formatting.chooseAttachments()
                    } else {
                        store.addAttachments()
                    }
                } label: { Image(systemName: "paperclip") }
                    .help("Add images or attachments")
                    .accessibilityLabel("Add attachments")
                    .disabled(isTrashed)
                Spacer(minLength: 4)
                Button {
                    store.exportMarkdown(note)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export as Markdown, HTML or plain text")
                .accessibilityLabel("Export note")
                Menu {
                    Picker("Editor Mode", selection: $mode) {
                        ForEach(EditorMode.allCases, id: \.rawValue) { mode in
                            if note.contentFormat != .formatted || mode != .split {
                                Text(note.contentFormat == .formatted && mode == .write ? "Compose" : mode.rawValue).tag(mode.rawValue)
                            }
                        }
                    }.disabled(isTrashed)
                    Button("Edit Tags") { showingTags.toggle() }
                    Menu("Move to Notebook") {
                        ForEach(store.library.notebooks) { notebook in
                            Button(notebook.name) { store.moveNotes([note.id], to: notebook.name) }
                        }
                    }.disabled(isTrashed)
                    Button(note.isPinned ? "Unpin Note" : "Pin Note") { store.update(note.id) { $0.isPinned.toggle() } }
                        .disabled(isTrashed)
                    Divider()
                    TextSizeButtons()
                    Button("Note History...") { showingHistory = true }
                        .disabled(isTrashed || (note.history ?? []).isEmpty)
                    Button("Linked Mentions...") { showingBacklinks = true }
                    if note.contentFormat == .formatted {
                        Button("Use Markdown Source Editor...") { confirmingSource = true }
                    }
                    Divider()
                    if isTrashed {
                        Button("Restore Note") { store.restore(note.id) }
                    } else {
                        Button("Move to Trash", role: .destructive) { store.trash(note.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Note actions")
                .accessibilityLabel("Note actions")
                ViewThatFits(in: .horizontal) {
                    searchField.frame(width: 180)
                    Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .help("Search notes").accessibilityLabel("Search notes")
                        .popover(isPresented: $showingSearch) {
                            searchField.padding().frame(width: 280).folioAppearance()
                                .onAppear { searchFocus.wrappedValue = true }
                        }
                }
            }
        .buttonStyle(.borderless)
        .padding(.leading, showNotebooks || showNotes ? 20 : 84)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(palette?.sidebarColor ?? Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        LibrarySearchField(focused: searchFocus)
    }

    private var sourceEditor: some View {
        SourceEditor(text: noteBinding(\.body), family: ReadingFont(rawValue: readingFont) ?? .system,
                     size: fontSize, dracula: palette != nil,
                     currentSource: { noteBinding(\.body).wrappedValue })
            .accessibilityLabel(note.contentFormat == .html ? "HTML source editor" : "Markdown editor")
    }

    private var preview: some View {
        MarkdownPreview(note: note, onImage: { imageURL = $0 })
    }

    private func noteBinding(_ keyPath: WritableKeyPath<Note, String>) -> Binding<String> {
        Binding(
            get: { store.library.notes.first { $0.id == note.id }?[keyPath: keyPath] ?? "" },
            set: { value in store.update(note.id) { $0[keyPath: keyPath] = value } }
        )
    }
}
