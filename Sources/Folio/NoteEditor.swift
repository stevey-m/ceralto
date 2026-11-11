import NotesCore
import SwiftUI

struct NoteEditor: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    let onPermanentDelete: () -> Void
    var isActive = true
    var searchFocus: FocusState<Bool>.Binding
    var toolbarWidth: Double
    @ViewState private var isPreviewing = false
    @ViewState private var initialized = false
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("showNoteDetails") private var showDetails = false
    @ViewState private var showingSearch = false
    @ThemeColors private var palette
    @AppStorage("readingFont") private var readingFont = ReadingFont.system.rawValue
    @ViewState private var tagsText = ""
    @FocusState private var tagsFocused: Bool
    @ViewState private var showingHistory = false
    @ViewState private var showingTags = false
    @ViewState private var confirmingSource = false
    @ViewState private var usesCompose = false
    @ViewState private var sourceEditingReason: String?
    @ViewState private var showingBacklinks = false
    @ViewState private var imageURL: URL?
    @StateObject private var formatting = FormattingActions()

    private var isTrashed: Bool { note.deletedAt != nil }

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
                NoteTitleField(text: noteBinding(\.title),
                               focusWhenAttached: isActive && note.title.isEmpty && note.body.isEmpty,
                               color: NSColor(palette?.foregroundColor ?? Color.primary)) {
                        if let editor = formatting.editor { editor.window?.makeFirstResponder(editor) }
                    }
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
            if isTrashed {
                preview
            } else if initialized {
                if let sourceEditingReason {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Rendered note").fontWeight(.medium)
                            Text("This layout needs source editing for changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        NoteToolbarButton(title: isPreviewing ? "Edit Source" : "Show Note") {
                            isPreviewing.toggle()
                        }
                    }
                    .font(.callout)
                    .padding(12)
                    .help(sourceEditingReason)
                    .background(.secondary.opacity(0.08))
                }
                ZStack {
                    VStack(spacing: 0) {
                        if usesCompose {
                            FormattedEditor(note: note, fontSize: fontSize,
                                            family: ReadingFont(rawValue: readingFont) ?? .system,
                                            dracula: palette != nil, actions: formatting) { body in
                                store.update(note.id) { $0.body = body }
                            } onError: { store.errorMessage = $0 } onImage: { imageURL = $0 }
                              currentSource: { noteBinding(\.body).wrappedValue }
                              onImportFiles: { try store.importComposeAttachments($0, to: note.id) }
                        } else {
                            sourceEditor
                        }
                    }
                    .disabled(isPreviewing)
                    .opacity(isPreviewing ? 0 : 1)
                    .allowsHitTesting(!isPreviewing)
                    .accessibilityHidden(isPreviewing)
                    if isPreviewing { preview }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .toolbar {
            if isActive {
                editorToolbar
            }
        }
        .onAppear {
            guard !initialized else { return }
            tagsText = note.tags.joined(separator: ", ")
            let newSourceNote = note.contentFormat == .markdown && note.title.isEmpty && note.body.isEmpty
            if !isTrashed && !newSourceNote { beginEditing() }
            initialized = true
        }
        .onChange(of: isTrashed) { _, trashed in
            if !trashed { beginEditing() }
        }
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
        .confirmationDialog("Switch to source editing?", isPresented: $confirmingSource, titleVisibility: .visible) {
            Button("Use Source Editor") {
                usesCompose = false
                sourceEditingReason = nil
                isPreviewing = false
            }
        } message: {
            Text("Source editing preserves the note's original Markdown or HTML. Its text and attachments will not be converted.")
        }
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(id: "note-formatting", placement: .automatic) {
            NoteFormattingControls(actions: formatting)
                .disabled(isTrashed || !usesCompose || isPreviewing || formatting.editor == nil)
                .help(usesCompose ? "Format selected text" : "Visual formatting is unavailable in source editing")
        }
        ToolbarItem(id: "note-attachments", placement: .automatic) {
                Button {
                    if usesCompose && !isPreviewing {
                        formatting.chooseAttachments()
                    } else {
                        store.addAttachments()
                    }
                } label: { Image(systemName: "paperclip") }
                    .help("Add images or attachments")
                    .accessibilityLabel("Add attachments")
                    .disabled(isTrashed)
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        #else
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        #endif
        ToolbarItem(id: "note-export", placement: .primaryAction) {
                Button {
                    store.exportMarkdown(note)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export as Markdown, HTML or plain text")
                .accessibilityLabel("Export note")
        }
        ToolbarItem(id: "note-actions", placement: .primaryAction) {
                Menu {
                    Toggle("Preview", isOn: $isPreviewing).disabled(isTrashed)
                    Button("Edit Tags") { showingTags.toggle() }
                    Menu("Move to Notebook") {
                        ForEach(store.library.notebooks) { notebook in
                            Button(notebook.name) { store.moveNotes([note.id], to: notebook.name) }
                        }
                    }.disabled(isTrashed)
                    Button(note.isPinned ? "Unpin Note" : "Pin Note") { store.update(note.id) { $0.isPinned.toggle() } }
                        .disabled(isTrashed)
                    Divider()
                    Section("Default Reading Size") { TextSizeButtons() }
                    Button("Note History...") { showingHistory = true }
                        .disabled(isTrashed || (note.history ?? []).isEmpty)
                    Button("Linked Mentions...") { showingBacklinks = true }
                    if usesCompose {
                        Button(note.contentFormat.usesHTML ? "Use HTML Source Editor..." : "Use Markdown Source Editor...") {
                            confirmingSource = true
                        }
                    } else {
                        Button("Use Visual Editor", action: beginEditing).disabled(isTrashed)
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
                .menuIndicator(.hidden)
        }
        if toolbarWidth >= 560 {
            ToolbarItem(id: "library-search", placement: .primaryAction) {
                searchField.frame(width: min(220, max(120, toolbarWidth - 600)))
            }
        } else {
            ToolbarItem(id: "library-search-compact", placement: .primaryAction) {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("Search notes").accessibilityLabel("Search notes")
                    .popover(isPresented: $showingSearch) {
                        searchField.padding().frame(width: 280).folioAppearance()
                            .onAppear { searchFocus.wrappedValue = true }
                    }
            }
        }
    }

    private var searchField: some View {
        LibrarySearchField(focused: searchFocus)
    }

    private func beginEditing() {
        do {
            if note.contentFormat.usesHTML { _ = try FormattedPage(html: note.body) }
            else { _ = try FormattedPage(markdown: note.body) }
            usesCompose = true
            sourceEditingReason = nil
            isPreviewing = false
        } catch {
            usesCompose = false
            isPreviewing = true
            sourceEditingReason = error.localizedDescription
        }
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

private struct NoteTitleField: NSViewRepresentable {
    @Binding var text: String
    let focusWhenAttached: Bool
    let color: NSColor
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> TitleField {
        let field = TitleField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .semibold)
        field.placeholderString = "Untitled note"
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("Note title")
        return field
    }

    func updateNSView(_ field: TitleField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = color
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        field.isSelectable = isEnabled
        field.needsInitialFocus = focusWhenAttached && isEnabled
        field.requestInitialFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor final class TitleField: NSTextField {
        var needsInitialFocus = false
        private var focusedInitially = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            requestInitialFocus()
        }

        func requestInitialFocus() {
            guard needsInitialFocus, !focusedInitially, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsInitialFocus, !self.focusedInitially, self.isEditable,
                      let window = self.window else { return }
                self.focusedInitially = window.makeFirstResponder(self)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoteTitleField
        init(parent: NoteTitleField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
