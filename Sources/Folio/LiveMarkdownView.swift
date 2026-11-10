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
    @Published var text = ""
    @Published private(set) var baseline: MarkdownSource?
    @Published private(set) var conflict = false
    @Published private(set) var refreshing = false
    @Published var message = "Open a separate Markdown folder. Your Deltos library stays unchanged."
    private var scopedURL: URL?
    private var accessing = false
    private let previewID = UUID()
    private let notebookID = UUID()
    var dirty: Bool { baseline != nil && text != baseline?.text }

    func open(_ url: URL, avoiding libraryURL: URL) throws {
        guard !dirty else { throw NoteWorkflowError("Save your current draft, or explicitly discard it, before switching folders.") }
        let granted = url.startAccessingSecurityScopedResource()
        do {
            let candidate = try LiveMarkdownFolder(root: url)
            let library = libraryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.root != library,
                  !candidate.root.path.hasPrefix(library.path + "/"),
                  !library.path.hasPrefix(candidate.root.path + "/") else {
                throw NoteWorkflowError("Choose a folder separate from Deltos's existing library storage.")
            }
            let listed = try candidate.entries()
            if accessing { scopedURL?.stopAccessingSecurityScopedResource() }
            scopedURL = url
            accessing = granted
            folder = candidate
            entries = listed
            selectedPath = nil
            baseline = nil
            text = ""
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
        panel.message = "Open an ordinary Markdown folder, not Joplin's internal sync folder. Deltos edits files in place. Keep an independent backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try open(url, avoiding: libraryURL) }
        catch { message = "Could not open folder: \(error.localizedDescription)" }
    }

    func select(_ path: String) {
        guard path != selectedPath else { return }
        guard confirmLeavingDraft() else { return }
        do {
            guard let folder else { throw NoteWorkflowError("Open a Markdown folder first.") }
            let loaded = try folder.read(path)
            selectedPath = path
            baseline = loaded
            text = loaded.text
            conflict = false
            message = "Editing \(path). Save writes the original file; your normal Deltos library is separate."
        } catch { message = "Could not open note: \(error.localizedDescription)" }
    }

    @discardableResult func save() -> Bool {
        guard let folder, let path = selectedPath, let baseline else {
            message = "Select a Markdown note before saving."
            return false
        }
        do {
            self.baseline = try folder.save(text, at: path, expectedDigest: baseline.digest)
            conflict = false
            message = "Saved \(path) locally. Cloud delivery is not verified."
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
                message = "The selected file changed outside Deltos. Your unsaved draft is preserved. Reload disk or save a separate copy."
            } else {
                self.baseline = disk
                text = disk.text
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
            baseline = disk
            text = disk.text
            conflict = false
            message = "Reloaded \(path) from disk."
        } catch { message = "Reload failed; draft preserved. \(error.localizedDescription)" }
    }

    func create(path: String, directory: Bool, copyDraft: Bool = false) {
        guard let folder else { message = "Open a Markdown folder first."; return }
        if !copyDraft, !confirmLeavingDraft() { return }
        do {
            if directory { try folder.createDirectory(at: path) }
            else { try folder.createNote(at: path, text: copyDraft ? text : "") }
            entries = try folder.entries()
            if !directory {
                let loaded = try folder.read(path)
                selectedPath = path
                baseline = loaded
                text = loaded.text
                conflict = false
            }
            message = "Created \(path)."
        } catch { message = "Create failed; existing files were not overwritten. \(error.localizedDescription)" }
    }

    func move(_ source: String, to destination: String) {
        guard let folder else { message = "Open a Markdown folder first."; return }
        guard confirmLeavingDraft() else { return }
        do {
            try folder.move(source, to: destination)
            if let selectedPath, selectedPath == source || selectedPath.hasPrefix(source + "/") {
                self.selectedPath = destination + String(selectedPath.dropFirst(source.count))
            }
            entries = try folder.entries()
            message = "Moved to \(destination). Relative attachment links and notebook-qualified links are not rewritten; check them after moving."
        } catch { message = "Move failed: \(error.localizedDescription)" }
    }

    func confirmLeavingDraft() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your Markdown changes?"
        alert.informativeText = "The draft for \(selectedPath ?? "this note") has not been saved. A file changed outside Deltos will not be overwritten."
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
            if let baseline { text = baseline.text }
            return true
        case .cancel: return false
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
    @ViewState private var mode = "Split"
    @ViewState private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Open Markdown Folder...") { model.chooseFolder(avoiding: library.libraryURL) }
                Text(model.folder?.root.path ?? "Separate live Markdown library")
                    .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if model.folder != nil {
                    Menu("New") {
                        Button("Markdown Note...") { draft = MarkdownPathDraft(path: "Untitled.md") }
                        Button("Folder...") { draft = MarkdownPathDraft(directory: true) }
                    }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
            }.padding(12)
            Divider()
            HSplitView {
                List {
                    ForEach(children(of: "")) { entry in row(entry) }
                }
                .listStyle(.sidebar).frame(minWidth: 200, idealWidth: 250, maxWidth: 380)
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
                                TextEditor(text: $model.text)
                                    .font(.system(size: 15, design: .monospaced))
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
                if model.conflict {
                    HStack {
                        Button("Reload Disk Version...") { reload = true }
                        Button("Save Draft as New Copy...") {
                            let parent = model.selectedPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
                            draft = MarkdownPathDraft(copyDraft: true, path: (parent.isEmpty ? "" : parent + "/") + "Recovered draft.md")
                        }
                    }
                }
                Text("Edits are saved explicitly. External changes are checked every 3 seconds while this window is open. This folder is not covered by your normal library's backups or sync.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowCloseGuard(model: model))
        .folioAppearance()
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
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
        }.padding(24).frame(width: 480)
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
