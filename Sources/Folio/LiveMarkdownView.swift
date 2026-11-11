import AppKit
import NotesCore
import SwiftUI

struct LiveMarkdownFocusKey: FocusedValueKey {
    typealias Value = LiveMarkdownStore
}

extension FocusedValues {
    var liveMarkdown: LiveMarkdownStore? {
        get { self[LiveMarkdownFocusKey.self] }
        set { self[LiveMarkdownFocusKey.self] = newValue }
    }
}

@MainActor
final class LiveMarkdownStore: ObservableObject {
    enum DraftDecision { case save, cancel, discard }
    @Published private(set) var folder: LiveMarkdownFolder?
    @Published private(set) var entries: [MarkdownEntry] = []
    @Published private(set) var selectedPath: String?
    @Published var text = "" {
        didSet { if !loadingDocument, text != oldValue { protectDraft() } }
    }
    @Published private(set) var baseline: MarkdownSource?
    @Published private(set) var conflict = false
    @Published private(set) var refreshing = false
    @Published var message = "Open a separate Markdown folder. Your Ceralto library stays unchanged."
    @Published private(set) var recoveryIssue: String?
    @Published private(set) var recoverable: [MarkdownDraft] = []
    @Published private(set) var hasRememberedFolder = false
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var searchReport: MarkdownSearchReport?
    @Published private(set) var searching = false
    @Published private(set) var searchError: String?
    let recovery: MarkdownRecovery
    private var loadingDocument = false
    private var remembered: MarkdownSession?
    private var attemptedReopen = false
    private var searchTask: Task<Void, Never>?
    private var searchWorker: Task<MarkdownSearchReport, Error>?
    private var searchID = UUID()
    private var scopedURL: URL?
    private var accessing = false
    private let previewID = UUID()
    private let notebookID = UUID()
    var dirty: Bool { baseline != nil && text != baseline?.text }

    init(stateDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Folio/LiveMarkdown", isDirectory: true)) {
        recovery = MarkdownRecovery(directory: stateDirectory)
        do {
            remembered = try recovery.session()
            hasRememberedFolder = remembered != nil
        } catch {
            hasRememberedFolder = true
            recoveryIssue = "The saved Markdown session could not be read and was preserved. Forget the remembered folder to reset it. \(error.localizedDescription)"
        }
    }

    func reopenLast(avoiding libraryURL: URL) {
        attemptedReopen = true
        guard folder == nil else { return }
        do {
            guard let session = try recovery.session() else { return }
            var stale = false
            let url = try URL(resolvingBookmarkData: session.bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            try open(url, avoiding: libraryURL, recoveringFrom: session.root)
            if let path = session.selectedPath { select(path) }
        } catch {
            message = "The remembered folder could not be reopened. Reconnect it with Open Markdown Folder; saved drafts have not been deleted. \(error.localizedDescription)"
        }
    }

    func resumeIfNeeded(avoiding libraryURL: URL) {
        guard !attemptedReopen else { return }
        reopenLast(avoiding: libraryURL)
    }

    func forgetFolder() {
        do {
            try recovery.forgetSession()
            remembered = nil
            hasRememberedFolder = false
            recoveryIssue = nil
            message = "Forgot the startup folder. The open folder, files and recovery drafts were not deleted."
        } catch { recoveryIssue = "Could not forget the saved folder: \(error.localizedDescription)" }
    }

    func open(_ url: URL, avoiding libraryURL: URL, recoveringFrom previousRoot: URL? = nil) throws {
        guard !dirty else { throw NoteWorkflowError("Save your current draft, or explicitly discard it, before switching folders.") }
        let granted = url.startAccessingSecurityScopedResource()
        do {
            let candidate = try LiveMarkdownFolder(root: url)
            let library = libraryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.root != library,
                  !candidate.root.path.hasPrefix(library.path + "/"),
                  !library.path.hasPrefix(candidate.root.path + "/") else {
                throw NoteWorkflowError("Choose a folder separate from Ceralto's existing library storage.")
            }
            let listed = try candidate.entries()
            var drafts = try recovery.drafts(for: candidate.root)
            let displaced = try previousRoot.map { previous in
                previous != candidate.root ? try recovery.drafts(for: previous) : []
            } ?? []
            for draft in displaced {
                let relocated = MarkdownDraft(root: candidate.root, path: draft.path,
                    original: draft.original, text: draft.text, updatedAt: draft.updatedAt)
                guard !drafts.contains(where: { $0.path == draft.path && $0 != relocated }) else {
                    throw NoteWorkflowError("Two local recovery drafts share a path after this folder moved. Both were preserved; inspect Local Recovery Files before reconnecting.")
                }
                try recovery.saveDraft(relocated)
                if !drafts.contains(relocated) { drafts.append(relocated) }
            }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            let session = MarkdownSession(bookmark: bookmark, root: candidate.root, selectedPath: nil)
            try recovery.saveSession(session)
            if accessing { scopedURL?.stopAccessingSecurityScopedResource() }
            scopedURL = url
            accessing = granted
            folder = candidate
            entries = listed
            setDocument(path: nil, source: nil, text: "")
            recoverable = drafts
            remembered = session
            hasRememberedFolder = true
            recoveryIssue = nil
            for draft in displaced {
                do { try recovery.removeDraft(root: draft.root, path: draft.path) }
                catch { recoveryIssue = "The folder reopened, but an older recovery copy could not be removed. Both copies were kept. \(error.localizedDescription)" }
            }
            attemptedReopen = true
            query = ""
            searchReport = nil
            conflict = false
            message = "Live folder open. Files stay here; use Save to write edits. Hidden files and symbolic links are excluded."
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func chooseFolder(avoiding libraryURL: URL) {
        guard confirmLeavingDraft() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Open an ordinary Markdown folder, not Joplin's internal sync folder. Ceralto edits files in place. Keep an independent backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try open(url, avoiding: libraryURL) }
        catch { message = "Could not open folder: \(error.localizedDescription)" }
    }

    func select(_ path: String) {
        guard path != selectedPath else { return }
        guard confirmLeavingDraft() else { return }
        do {
            guard let folder else { throw NoteWorkflowError("Open a Markdown folder first.") }
            if let draft = recoverable.first(where: { $0.path == path }) {
                try restoreDraft(draft)
                return
            }
            let loaded = try folder.read(path)
            setDocument(path: path, source: loaded, text: loaded.text)
            rememberSelection()
            conflict = false
            message = "Editing \(path). Save writes the original file; your normal Ceralto library is separate."
        } catch { message = "Could not open note: \(error.localizedDescription)" }
    }

    @discardableResult func save() -> Bool {
        guard let folder, let path = selectedPath, let baseline else {
            message = "Select a Markdown note before saving."
            return false
        }
        do {
            let saved = try folder.save(text, at: path, expectedDigest: baseline.digest)
            self.baseline = saved
            conflict = false
            message = "Saved \(path) locally. Cloud delivery is not verified."
            do { try removeRecovery(path) }
            catch {
                recoveryIssue = "Your Markdown file was saved, but its old local recovery record could not be removed. \(error.localizedDescription)"
            }
            if !query.isEmpty { search() }
            return true
        } catch {
            conflict = true
            message = "Save blocked; your draft is preserved. \(error.localizedDescription)"
            return false
        }
    }

    func refresh() async {
        guard !refreshing, let folder else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let listed = try await Task.detached { try folder.entries() }.value
            guard self.folder?.root == folder.root else { return }
            if entries != listed { entries = listed }
            guard let path = selectedPath, let baseline else { return }
            let disk = try folder.read(path)
            guard disk.digest != baseline.digest else { return }
            if dirty {
                conflict = true
                message = "The selected file changed outside Ceralto. Your unsaved draft is preserved. Reload disk or save a separate copy."
            } else {
                setDocument(path: path, source: disk, text: disk.text)
                conflict = false
                message = "Reloaded external changes to \(path)."
            }
        } catch {
            conflict = selectedPath != nil
            message = "Folder refresh failed; no draft was discarded. \(error.localizedDescription)"
        }
    }

    func reloadDisk() {
        guard let folder, let path = selectedPath else { return }
        do {
            let disk = try folder.read(path)
            try removeRecovery(path)
            setDocument(path: path, source: disk, text: disk.text)
            conflict = false
            message = "Reloaded \(path) from disk."
        } catch { message = "Reload failed; draft preserved. \(error.localizedDescription)" }
    }

    func create(path: String, directory: Bool, copyDraft: Bool = false) {
        guard let folder else { message = "Open a Markdown folder first."; return }
        if !copyDraft, !confirmLeavingDraft() { return }
        do {
            let previousPath = selectedPath
            if directory { try folder.createDirectory(at: path) }
            else { try folder.createNote(at: path, text: copyDraft ? text : "") }
            entries = try folder.entries()
            if !directory {
                let loaded = try folder.read(path)
                if copyDraft, let previousPath { try removeRecovery(previousPath) }
                setDocument(path: path, source: loaded, text: loaded.text)
                rememberSelection()
                conflict = false
            }
            message = "Created \(path)."
            if !query.isEmpty { search() }
        } catch { message = "Create failed; existing files were not overwritten. \(error.localizedDescription)" }
    }

    func move(_ source: String, to destination: String) {
        guard let folder else { message = "Open a Markdown folder first."; return }
        guard confirmLeavingDraft() else { return }
        do {
            guard !recoverable.contains(where: { $0.path == source || $0.path.hasPrefix(source + "/") }) else {
                throw NoteWorkflowError("Recover or explicitly discard drafts in this branch before moving it.")
            }
            try folder.move(source, to: destination)
            if let selectedPath, selectedPath == source || selectedPath.hasPrefix(source + "/") {
                self.selectedPath = destination + String(selectedPath.dropFirst(source.count))
            }
            entries = try folder.entries()
            rememberSelection()
            if !query.isEmpty { search() }
            message = "Moved to \(destination). Relative attachment links and notebook-qualified links are not rewritten; check them after moving."
        } catch { message = "Move failed: \(error.localizedDescription)" }
    }

    func confirmLeavingDraft() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your Markdown changes?"
        alert.informativeText = "The draft for \(selectedPath ?? "this note") has not been saved. A file changed outside Ceralto will not be overwritten."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Draft")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return resolveDraft(.save)
        case .alertThirdButtonReturn: return resolveDraft(.discard)
        default: return resolveDraft(.cancel)
        }
    }

    func resolveDraft(_ decision: DraftDecision) -> Bool {
        switch decision {
        case .save: return save()
        case .discard:
            do {
                if let path = selectedPath { try removeRecovery(path) }
                if let baseline { setDocument(path: selectedPath, source: baseline, text: baseline.text) }
                conflict = false
            } catch {
                recoveryIssue = "Could not discard the recovery draft. Your text is preserved. \(error.localizedDescription)"
                return false
            }
            return true
        case .cancel: return false
        }
    }

    private func setDocument(path: String?, source: MarkdownSource?, text: String) {
        loadingDocument = true
        defer { loadingDocument = false }
        selectedPath = path
        baseline = source
        self.text = text
    }

    private func rememberSelection() {
        guard var session = remembered else { return }
        session.selectedPath = selectedPath
        do {
            try recovery.saveSession(session)
            remembered = session
        } catch { recoveryIssue = "Could not remember the selected note: \(error.localizedDescription)" }
    }

    private func protectDraft() {
        guard let folder, let path = selectedPath, let baseline else { return }
        do {
            if dirty {
                let draft = MarkdownDraft(root: folder.root, path: path, original: baseline, text: text)
                try recovery.saveDraft(draft)
                recoverable.removeAll { $0.path == path }
                recoverable.insert(draft, at: 0)
            } else {
                try removeRecovery(path)
            }
            recoveryIssue = nil
        } catch {
            recoveryIssue = "Your latest draft is only in memory; local recovery could not be updated. Save or copy your text before quitting. \(error.localizedDescription)"
        }
    }

    private func removeRecovery(_ path: String) throws {
        guard let folder else { return }
        try recovery.removeDraft(root: folder.root, path: path)
        recoverable.removeAll { $0.path == path }
        recoveryIssue = nil
    }

    private func restoreDraft(_ draft: MarkdownDraft) throws {
        guard let folder else { throw NoteWorkflowError("Open the draft's Markdown folder first.") }
        guard draft.root == folder.root else { throw NoteWorkflowError("This draft belongs to a different Markdown folder.") }
        let disk: MarkdownSource?
        do { disk = try folder.read(draft.path) }
        catch {
            setDocument(path: draft.path, source: draft.original, text: draft.text)
            conflict = true
            rememberSelection()
            message = "Recovered \(draft.path) locally, but its disk file could not be read. Save a new copy to keep your draft. \(error.localizedDescription)"
            return
        }
        if disk?.text == draft.text, let disk {
            try removeRecovery(draft.path)
            setDocument(path: draft.path, source: disk, text: disk.text)
            conflict = false
            message = "The saved file already contains the recovered draft."
        } else {
            setDocument(path: draft.path, source: draft.original, text: draft.text)
            conflict = disk?.digest != draft.original.digest
            message = conflict
                ? "Recovered \(draft.path). The file changed outside Ceralto; reload disk or save your draft as a new copy."
                : "Recovered unsaved changes to \(draft.path). Review them, then Save or explicitly discard."
        }
        rememberSelection()
    }

    func recover(_ draft: MarkdownDraft) {
        if dirty, selectedPath == draft.path {
            message = "This draft is already open. Your latest text has been kept."
            return
        }
        guard !dirty || selectedPath == draft.path else {
            guard confirmLeavingDraft() else { return }
            select(draft.path)
            return
        }
        do { try restoreDraft(draft) }
        catch { message = "Could not recover draft; its local file was preserved. \(error.localizedDescription)" }
    }

    func search() {
        searchTask?.cancel()
        searchWorker?.cancel()
        let id = UUID()
        searchID = id
        searchReport = nil
        searchError = nil
        guard let folder, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searching = false
            return
        }
        let query = query
        searching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let worker = Task.detached { try folder.search(query) }
                self?.searchWorker = worker
                let report = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, self.searchID == id, !Task.isCancelled else { return }
                self.searchReport = report
                self.searching = false
            } catch is CancellationError {
                // A newer query or folder owns the search state now.
            } catch {
                guard let self, self.searchID == id else { return }
                self.searchError = "Search failed: \(error.localizedDescription)"
                self.searching = false
            }
        }
    }

    var previewNote: Note? {
        guard let folder, let path = selectedPath else { return nil }
        return Note(id: previewID, notebookID: notebookID,
                    title: (path as NSString).lastPathComponent,
                    body: text, importedSourceURL: folder.root.appendingPathComponent(path),
                    importedRootURL: folder.root)
    }
}

private struct MarkdownPathDraft: Identifiable {
    let id = UUID()
    var source: String?
    var directory = false
    var copyDraft = false
    var path = ""
}

struct LiveMarkdownView: View {
    @ObservedObject var model: LiveMarkdownStore
    @EnvironmentObject private var library: NotesStore
    @ViewState private var draft: MarkdownPathDraft?
    @ViewState private var reload = false
    @ViewState private var forget = false
    @ViewState private var mode = "Split"
    @ViewState private var expanded: Set<String> = []
    @ThemeColors private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Open Markdown Folder...") { model.chooseFolder(avoiding: library.libraryURL) }
                Menu {
                    Button("Reopen Last Folder") { model.reopenLast(avoiding: library.libraryURL) }
                        .disabled(!model.hasRememberedFolder || model.folder != nil)
                    Button("Forget Remembered Folder...") { forget = true }
                        .disabled(!model.hasRememberedFolder)
                    Button("Reveal Local Recovery Files") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.recovery.directory])
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("Remembered folder and local recovery")
                .accessibilityLabel("Remembered folder and local recovery")
                Text(model.folder?.root.path ?? "Separate live Markdown library")
                    .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if model.folder != nil {
                    Menu("New") {
                        Button("Markdown Note...") { draft = MarkdownPathDraft(path: "Untitled.md") }
                        Button("Folder...") { draft = MarkdownPathDraft(directory: true) }
                    }
                    Button("Refresh") { Task { await model.refresh(); model.search() } }.disabled(model.refreshing)
                }
            }.padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search saved Markdown files", text: $model.query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search saved Markdown files")
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear Markdown search")
                        }
                    }.padding(10)
                    Divider()
                    if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        List { ForEach(children(of: "")) { entry in row(entry) } }
                            .listStyle(.sidebar)
                    } else {
                        searchResults
                    }
                }
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 400)
                .folioSidebar()
                VStack(spacing: 0) {
                    if let path = model.selectedPath {
                        HStack {
                            Text(path + (model.dirty ? " *" : "")).lineLimit(1).help(path)
                            Spacer()
                            Picker("View", selection: $mode) {
                                Text("Source").tag("Source")
                                Text("Split").tag("Split")
                                Text("Preview").tag("Preview")
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                            Button("Save") { model.save() }
                        }.padding(12)
                        Divider()
                        HSplitView {
                            if mode != "Preview" {
                                SourceEditor(text: $model.text, family: .monospace, size: 15,
                                             dracula: palette != nil,
                                             currentSource: { model.text }, accessibilityLabel: "Live Markdown source")
                                    .background(.background)
                                    .frame(minWidth: 220)
                                    .accessibilityLabel("Live Markdown source")
                            }
                            if mode != "Source", let note = model.previewNote {
                                MarkdownPreview(note: note, resolveLibraryLinks: false).frame(minWidth: 220)
                            }
                        }
                    } else {
                        ContentUnavailableView("Live Markdown", systemImage: "folder",
                            description: Text("Open a folder, then select a Markdown file. Subfolders stay on disk. Existing files are not imported or converted."))
                    }
                }.frame(minWidth: 480)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(model.message).font(.caption).textSelection(.enabled)
                if let issue = model.recoveryIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                } else if model.dirty {
                    Text("Draft protected locally. Save writes your Markdown file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.recoverable.isEmpty {
                    Menu("Local Drafts (\(model.recoverable.count))") {
                        ForEach(model.recoverable) { saved in
                            Button(saved.path) { model.recover(saved) }
                        }
                    }.help("Recover unsaved text, including drafts whose original file moved or disappeared.")
                }
                if model.conflict {
                    HStack {
                        Button("Reload Disk Version...") { reload = true }
                        Button("Save Draft as New Copy...") {
                            let parent = model.selectedPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
                            draft = MarkdownPathDraft(copyDraft: true, path: (parent.isEmpty ? "" : parent + "/") + "Recovered draft.md")
                        }
                    }
                }
                Text("Save writes files explicitly. Local drafts aid crash recovery, not backup or sync. Search reads saved files only. External changes are checked every 3 seconds.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .background(.background)
        .background(WindowCloseGuard(model: model))
        .folioAppearance()
        .onChange(of: model.selectedPath) { _, path in revealSelection(path) }
        .onAppear { revealSelection(model.selectedPath) }
        .task {
            model.resumeIfNeeded(avoiding: library.libraryURL)
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
        .confirmationDialog("Forget the remembered Markdown folder?", isPresented: $forget, titleVisibility: .visible) {
            Button("Forget Folder", role: .destructive, action: model.forgetFolder)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears startup access and selection only. Your files and local recovery drafts are not deleted.")
        }
        .confirmationDialog("Discard this draft and load the disk version?", isPresented: $reload, titleVisibility: .visible) {
            Button("Discard Draft and Reload", role: .destructive, action: model.reloadDisk)
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $draft) { item in
            MarkdownPathSheet(draft: item) { path in
                if let source = item.source { model.move(source, to: path) }
                else { model.create(path: path, directory: item.directory, copyDraft: item.copyDraft) }
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.searching { ProgressView().controlSize(.small); Text("Searching saved files…") }
                else if let report = model.searchReport {
                    Text(report.truncated ? "First \(report.matches.count) matches — refine search"
                         : report.matches.count == 1 ? "1 match" : "\(report.matches.count) matches")
                }
                Spacer()
                Button { model.search() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Search disk again").accessibilityLabel("Search disk again")
            }.font(.caption).padding(.horizontal, 10).padding(.top, 8)
            if let error = model.searchError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10)
            }
            if let report = model.searchReport {
                if !report.unreadable.isEmpty {
                    DisclosureGroup("\(report.unreadable.count) files could not be searched") {
                        ScrollView {
                            Text(report.unreadable.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        }.frame(maxHeight: 140)
                    }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
                }
                List(report.matches) { match in
                    Button { model.select(match.path) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.path).fontWeight(model.selectedPath == match.path ? .bold : .medium)
                            Text(match.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    .folioListRow(selected: model.selectedPath == match.path)
                }.listStyle(.sidebar)
            } else { Spacer() }
        }
    }

    private func revealSelection(_ path: String?) {
        guard let path else { return }
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            expanded.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    private func children(of path: String) -> [MarkdownEntry] {
        model.entries.filter {
            let parent = ($0.path as NSString).deletingLastPathComponent
            return parent == path
        }
    }

    private func row(_ entry: MarkdownEntry) -> AnyView {
        AnyView(Group {
            if entry.isDirectory {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(entry.path) }, set: {
                    if $0 { expanded.insert(entry.path) } else { expanded.remove(entry.path) }
                })) {
                    ForEach(children(of: entry.path)) { child in row(child) }
                } label: { Label(entry.name, systemImage: "folder") }
            } else {
                Button { model.select(entry.path) } label: {
                    Label(entry.name, systemImage: "doc.text")
                        .fontWeight(model.selectedPath == entry.path ? .bold : .regular)
                }.buttonStyle(.plain)
            }
        }
        .folioListRow(selected: model.selectedPath == entry.path)
        .contextMenu {
            Button("Rename or Move...") { draft = MarkdownPathDraft(source: entry.path, path: entry.path) }
            Button("Reveal in Finder") {
                if let root = model.folder?.root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(entry.path)]) }
            }
        })
    }
}

private struct MarkdownPathSheet: View {
    let draft: MarkdownPathDraft
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var path: String

    init(draft: MarkdownPathDraft, submit: @escaping (String) -> Void) {
        self.draft = draft
        self.submit = submit
        _path = ViewState(initialValue: draft.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.source != nil ? "Rename or move" : draft.directory ? "New folder" : "New Markdown note").font(.title2)
            TextField("Relative path, e.g. Work/Ideas.md", text: $path).textFieldStyle(.roundedBorder)
            Text("Enter a path relative to the open folder. Parent folders must exist. Existing files are never overwritten. Moving files does not rewrite links.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") { submit(path); dismiss() }.keyboardShortcut(.defaultAction).disabled(path.isEmpty)
            }
        }.padding(24).frame(width: 480).folioAppearance()
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let model: LiveMarkdownStore
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        let coordinator = context.coordinator
        view.onWindow = { coordinator.install(on: $0) }
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if let window = view.window { coordinator.install(on: window) }
        }
    }

    @MainActor final class WindowProbe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: LiveMarkdownStore
        // NSObject's forwarding hooks are nonisolated; access this AppKit delegate only on the main thread.
        nonisolated(unsafe) weak var previous: (any NSWindowDelegate)?
        init(model: LiveMarkdownStore) { self.model = model }
        func install(on window: NSWindow) {
            guard window.delegate !== self else { return }
            previous = window.delegate
            window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            model.confirmLeavingDraft() && (previous?.windowShouldClose?(sender) ?? true)
        }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard Thread.isMainThread else { return false }
            return previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return super.forwardingTarget(for: selector) }
            let delegate = previous
            return delegate?.responds(to: selector) == true ? delegate : super.forwardingTarget(for: selector)
        }
    }
}
