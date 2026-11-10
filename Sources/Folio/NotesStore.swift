#if os(macOS)
import AppKit
#endif
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

enum NoteScope: Hashable {
    case all, pinned, trash
    case notebook(UUID)
    case tag(String)
    case folder(String, [UUID])
    case smart(UUID)

    func includes(_ note: Note) -> Bool {
        if self == .trash { return note.deletedAt != nil }
        guard note.deletedAt == nil else { return false }
        switch self {
        case .all: return true
        case .pinned: return note.isPinned
        case .trash: return false
        case .notebook(let id): return note.notebookID == id
        case .tag(let tag): return note.tags.contains(tag)
        case .folder(_, let ids): return ids.contains(note.notebookID)
        case .smart: return true
        }
    }
}

struct NotebookDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var name = ""
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var library = Library(notebooks: [])
    @Published var scope: NoteScope? = .all
    @Published var selectedNoteID: UUID? {
        didSet {
            #if os(macOS)
            guard isLoaded, !restoringWorkspace, oldValue != selectedNoteID else { return }
            workspace.select(selectedNoteID, replacingCurrent: true)
            persistWorkspace()
            #endif
        }
    }
    @Published private(set) var workspace = DocumentWorkspace()
    @Published var showingCommands = false
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var notebookDraft: NotebookDraft?
    @Published var smartFolderDraft: SmartFolder?
    @Published private(set) var smartFolders: [SmartFolder] = []
    @Published private(set) var smartFoldersAvailable = true
    @Published var showingFinder = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncMessage = "Offline. No shared folder connected."
    @Published private(set) var extensions: [NoteExtension] = []
    @Published private(set) var isImportingJoplin = false
    @Published var importSummary: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var hasUnsavedChanges = false
    private let storage: LibraryStorage
    private let preferences: UserDefaults
    private var restoringWorkspace = false
    var libraryURL: URL { storage.url }
    let isReadOnly: Bool
    private var syncFolder: URL?
    private var bookmarkURL: URL { storage.url.deletingLastPathComponent().appendingPathComponent("sync-folder.bookmark") }

    init(storage: LibraryStorage = .applicationDefault, readOnly: Bool = false, preferences: UserDefaults = .standard) {
        self.storage = storage
        self.preferences = preferences
        isReadOnly = readOnly
        load()
        #if os(macOS)
        reloadSmartFolders()
        #endif
        restoreSyncFolder()
        if !readOnly { reloadExtensions() }
    }

    var visibleNotes: [Note] {
        let parsed = NoteQuery(query)
        let saved = activeSmartFolder.map { NoteQuery($0.query) }
        let names = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        let missingSmartFolder: Bool
        if case .smart = scope { missingSmartFolder = activeSmartFolder == nil }
        else { missingSmartFolder = false }
        return library.notes.filter {
            !missingSmartFolder && resolvedScope.includes($0) &&
                parsed.matches($0, notebook: names[$0.notebookID] ?? "") &&
                (saved?.matches($0, notebook: names[$0.notebookID] ?? "") ?? true)
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var resolvedScope: NoteScope {
        guard case .folder(let path, _) = scope else { return scope ?? .all }
        let ids = library.notebooks.filter { $0.name == path || $0.name.hasPrefix(path + "/") }.map(\.id)
        return .folder(path, ids)
    }

    var navigationFolder: NotebookBranch? {
        let branches = NotebookBranch.build(library.notebooks)
        switch scope {
        case .notebook(let id):
            return branches.first { $0.descendants.contains(id) }
        case .folder(let path, _):
            return branches.first { path == $0.id || path.hasPrefix($0.id + "/") }
        default:
            return nil
        }
    }

    var mainFolderScope: NoteScope? {
        get {
            guard let folder = navigationFolder else { return scope }
            return .folder(folder.id, folder.descendants)
        }
        set { scope = newValue }
    }

    var outlineNotes: [Note] {
        guard let folder = navigationFolder else { return visibleNotes }
        let parsed = NoteQuery(query)
        let names = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        return library.notes.filter {
            $0.deletedAt == nil && folder.descendants.contains($0.notebookID) &&
                parsed.matches($0, notebook: names[$0.notebookID] ?? "")
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var selectedNote: Note? {
        library.notes.first { $0.id == selectedNoteID }
    }

    var tags: [String] {
        Array(Set(library.notes.filter { $0.deletedAt == nil }.flatMap(\.tags))).sorted()
    }

    var scopeTitle: String {
        switch scope ?? .all {
        case .all: "All Notes"
        case .pinned: "Pinned"
        case .trash: "Trash"
        case .notebook(let id): library.notebooks.first { $0.id == id }?.name ?? "Notebook"
        case .tag(let tag): "#\(tag)"
        case .folder(let name, _): name
        case .smart: activeSmartFolder?.name ?? "Smart Folder"
        }
    }

    var currentNotebookID: UUID? {
        if case .smart = scope, let selectedNote { return selectedNote.notebookID }
        if case .notebook(let id) = scope {
            if let selectedNote, navigationFolder?.descendants.contains(selectedNote.notebookID) == true {
                return selectedNote.notebookID
            }
            return id
        }
        if case .folder(_, let ids) = resolvedScope {
            if let selectedNote, ids.contains(selectedNote.notebookID) { return selectedNote.notebookID }
            return navigationFolder?.notebooks.first?.id ?? ids.first
        }
        return library.notebooks.first?.id
    }

    var activeSmartFolder: SmartFolder? {
        guard case .smart(let id) = scope else { return nil }
        return smartFolders.first { $0.id == id }
    }

    var searchError: String? { NoteQuery(query).errorMessage }

    var smartFolderStorage: SmartFolderStorage {
        SmartFolderStorage(url: storage.url.deletingLastPathComponent().appendingPathComponent("smart-folders.json"))
    }

    func reloadSmartFolders() {
        do {
            smartFolders = try smartFolderStorage.load()
            smartFoldersAvailable = true
        } catch {
            smartFoldersAvailable = false
            errorMessage = "Could not open smart folders. Your notes are unaffected and the saved file has not been replaced: \(error.localizedDescription)"
        }
    }

    func smartFolderCount(_ folder: SmartFolder) -> Int {
        let parsed = NoteQuery(folder.query)
        let names = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        return library.notes.filter {
            $0.deletedAt == nil && parsed.matches($0, notebook: names[$0.notebookID] ?? "")
        }.count
    }

    func draftSmartFolder() {
        guard isLoaded, !isReadOnly else {
            errorMessage = "Open an editable library before creating smart folders."
            return
        }
        guard scope != .trash else {
            errorMessage = "Smart folders search active notes, not Trash."
            return
        }
        guard smartFoldersAvailable else {
            errorMessage = "Reload your saved smart folders before adding or editing them."
            return
        }
        var terms: [String] = []
        switch scope {
        case .notebook(let id):
            if let notebook = library.notebooks.first(where: { $0.id == id }) {
                terms.append("notebook:" + NoteQuery.quoted(notebook.name))
            }
        case .folder(let path, _): terms.append("notebook:" + NoteQuery.quoted(path))
        case .tag(let tag): terms.append("tag:" + NoteQuery.quoted(tag))
        case .pinned: terms.append("is:pinned")
        case .smart: if let folder = activeSmartFolder { terms.append(folder.query) }
        default: break
        }
        if !query.isEmpty { terms.append(query) }
        smartFolderDraft = SmartFolder(name: "", query: terms.joined(separator: " "))
    }

    func saveSmartFolder(_ folder: SmartFolder) throws {
        guard isLoaded, !isReadOnly, smartFoldersAvailable else {
            throw SmartFolderError("Open your library and reload your saved smart folders before changing them.")
        }
        var candidate = smartFolders
        if let index = candidate.firstIndex(where: { $0.id == folder.id }) { candidate[index] = folder }
        else { candidate.append(folder) }
        try smartFolderStorage.save(candidate)
        smartFolders = candidate
        scope = .smart(folder.id)
        query = ""
        reconcileSelection()
    }

    func deleteSmartFolder(_ id: UUID) {
        guard isLoaded, !isReadOnly, smartFoldersAvailable else {
            errorMessage = "Open your library and reload your saved smart folders before changing them."
            return
        }
        let candidate = smartFolders.filter { $0.id != id }
        do {
            try smartFolderStorage.save(candidate)
            smartFolders = candidate
            if scope == .smart(id) { scope = .all; query = ""; reconcileSelection() }
        } catch {
            errorMessage = "Could not delete the smart folder. Its saved rules and your notes are unchanged: \(error.localizedDescription)"
        }
    }

    func load() {
        do {
            let loaded = try storage.load()
            let next = loaded ?? (isReadOnly ? Library(notebooks: [Notebook(name: "Shared library")]) : Library.starter())
            #if os(macOS)
            if !isReadOnly { try storage.prepareRecoveryCopy() }
            #endif
            if loaded == nil { try storage.save(next) }
            library = next
            restoringWorkspace = true
            isLoaded = true
            hasUnsavedChanges = false
            selectedNoteID = visibleNotes.first?.id
            #if os(macOS)
            restoreWorkspace()
            #else
            restoringWorkspace = false
            #endif
        } catch {
            isLoaded = false
            errorMessage = "Could not open your notes: \(error.localizedDescription)\n\nYour existing library has not been overwritten. Location: \(storage.url.path)"
        }
    }

    func save() {
        guard isLoaded else { return }
        do {
            try storage.save(library)
            hasUnsavedChanges = false
        } catch {
            hasUnsavedChanges = true
            errorMessage = "Your latest changes are still in memory but could not be saved: \(error.localizedDescription)"
        }
    }

    func reconcileSelection() {
        if !outlineNotes.contains(where: { $0.id == selectedNoteID }) {
            selectedNoteID = outlineNotes.first?.id
        }
    }

    private var workspaceURL: URL { storage.url.deletingLastPathComponent().appendingPathComponent("workspace.json") }

    private func restoreWorkspace() {
        restoringWorkspace = true
        defer { restoringWorkspace = false }
        workspace = DocumentWorkspace()
        do {
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                workspace = try JSONDecoder().decode(DocumentWorkspace.self, from: Data(contentsOf: workspaceURL))
                try workspace.validate()
                workspace.retainNotes(Set(library.notes.map(\.id)))
                if let id = workspace.activeID { openNote(id) }
                else { selectedNoteID = nil }
            } else {
                workspace.select(selectedNoteID)
            }
        } catch {
            workspace = DocumentWorkspace()
            workspace.select(selectedNoteID)
            errorMessage = "Could not restore your document tabs. Your notes are unaffected: \(error.localizedDescription)"
        }
    }

    private func persistWorkspace() {
        guard !restoringWorkspace else { return }
        do {
            workspace.retainNotes(Set(library.notes.map(\.id)))
            try workspace.validate()
            try JSONEncoder().encode(workspace).write(to: workspaceURL, options: .atomic)
        } catch {
            errorMessage = "Could not save your document tabs. Note saving is separate: \(error.localizedDescription)"
        }
    }

    func closeTab(_ id: UUID) {
        let wasActive = workspace.activeID == id
        workspace.close(id)
        if wasActive {
            if let next = workspace.activeID { openNote(next) }
            else { selectedNoteID = nil }
        }
        persistWorkspace()
    }

    func navigateBack() {
        if let id = workspace.goBack() { openNote(id); persistWorkspace() }
    }

    func navigateForward() {
        if let id = workspace.goForward() { openNote(id); persistWorkspace() }
    }

    func showReference(_ id: UUID?) {
        guard id == nil || library.notes.contains(where: { $0.id == id }) else { return }
        workspace.setReference(id)
        persistWorkspace()
    }

    var referenceNote: Note? { library.notes.first { $0.id == workspace.referenceID } }

    func preferencesValue(_ key: String) -> Bool {
        preferences.object(forKey: key) == nil || preferences.bool(forKey: key)
    }

    func preferencesToggle(_ key: String) { preferences.set(!preferencesValue(key), forKey: key) }

    func setPaneVisibility(folders: Bool, notes: Bool) {
        preferences.set(folders, forKey: "showNotebookPane")
        preferences.set(notes, forKey: "showNoteListPane")
    }

    func createNote() {
        #if os(macOS)
        let format = preferences.string(forKey: "defaultNoteFormat") == NoteFormat.markdown.rawValue
            ? NoteFormat.markdown : .formatted
        createNote(format: format)
        #else
        createNote(format: .markdown)
        #endif
    }

    func createMarkdownNote() { createNote(format: .markdown) }

    private func createNote(format: NoteFormat) {
        guard isLoaded, !isReadOnly, let notebookID = currentNotebookID else { return }
        var note = Note(notebookID: notebookID, format: format)
        if case .tag(let tag) = scope { note.tags = [tag] }
        if scope == .pinned { note.isPinned = true }
        if scope == .trash { scope = .all }
        if case .smart = scope { scope = .all }
        query = ""
        library.notes.insert(note, at: 0)
        #if os(macOS)
        workspace.select(note.id)
        #endif
        selectedNoteID = note.id
        save()
    }

    var extensionsDirectory: URL {
        storage.url.deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true)
    }

    func reloadExtensions() {
        do { extensions = try NoteExtensions.load(from: extensionsDirectory) }
        catch { errorMessage = "Could not load extensions: \(error.localizedDescription)" }
    }

    func createFromTemplate(_ template: NoteTemplate) {
        guard isLoaded, !isReadOnly, let notebookID = currentNotebookID else { return }
        let now = Date()
        var tags = template.tags ?? []
        if case .tag(let tag) = scope { tags.append(tag) }
        let note = Note(notebookID: notebookID, title: template.render(template.title, date: now),
                        body: template.render(template.body, date: now), tags: tags,
                        isPinned: scope == .pinned, format: .markdown)
        if scope == .trash { scope = .all }
        if case .smart = scope { scope = .all }
        query = ""
        library.notes.insert(note, at: 0)
        #if os(macOS)
        workspace.select(note.id)
        #endif
        selectedNoteID = note.id
        save()
    }

    var inboxID: UUID? {
        library.notebooks.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }?.id
    }

    func capture(title: String, body: String) throws -> UUID {
        guard isLoaded, !isReadOnly else { throw LibraryError.invalidLibrary }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JoplinImportError.invalid("Add a thought before saving to Inbox.")
        }
        var candidate = library
        let notebookID: UUID
        if let existing = inboxID { notebookID = existing }
        else {
            let inbox = Notebook(name: "Inbox")
            candidate.notebooks.append(inbox)
            notebookID = inbox.id
        }
        let paragraphs = body.components(separatedBy: "\n").map {
            FormattedBlock(runs: [FormattedRun(text: $0)])
        }
        let note = Note(notebookID: notebookID, title: title,
                        body: FormattedPage(blocks: paragraphs).markdown(), format: .formatted)
        candidate.notes.insert(note, at: 0)
        try storage.save(candidate)
        library = candidate
        hasUnsavedChanges = false
        return note.id
    }

    func openNoteInNewTab(_ id: UUID) {
        guard library.notes.contains(where: { $0.id == id }) else { return }
        workspace.select(id)
        openNote(id)
        persistWorkspace()
    }

    func openNote(_ id: UUID) {
        guard let note = library.notes.first(where: { $0.id == id }) else { return }
        if activeSmartFolder != nil, visibleNotes.contains(where: { $0.id == id }) {
            selectedNoteID = id
            return
        }
        if note.deletedAt != nil {
            scope = .trash
        } else if let folder = NotebookBranch.build(library.notebooks).first(where: { $0.descendants.contains(note.notebookID) }) {
            scope = .folder(folder.id, folder.descendants)
        } else {
            scope = .all
        }
        query = ""
        selectedNoteID = id
    }

    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard isLoaded, !isReadOnly, let index = library.notes.firstIndex(where: { $0.id == id }) else { return }
        let previous = library.notes[index]
        change(&library.notes[index])
        guard library.notes[index] != previous else { return }
        library.notes[index].recordRevision(of: previous)
        library.notes[index].updatedAt = Date()
        save()
    }

    func restoreRevision(_ revision: NoteRevision, noteID: UUID) {
        guard !isReadOnly, let index = library.notes.firstIndex(where: { $0.id == noteID }),
              library.notes[index].deletedAt == nil else { return }
        let previous = library.notes[index]
        library.notes[index].title = revision.title
        library.notes[index].body = revision.body
        library.notes[index].format = revision.format
        library.notes[index].recordRevision(of: previous, force: true)
        library.notes[index].updatedAt = Date()
        save()
    }

    func setTags(_ id: UUID, text: String) {
        update(id) { $0.tags = Note.normalizedTags(text.components(separatedBy: ",")) }
    }

    func trash(_ id: UUID) {
        update(id) { $0.deletedAt = Date() }
        reconcileSelection()
    }

    func restore(_ id: UUID) {
        update(id) { $0.deletedAt = nil }
        reconcileSelection()
    }

    func permanentlyDelete(_ id: UUID) {
        guard isLoaded, !isReadOnly, library.notes.contains(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        library.notes.removeAll { $0.id == id }
        save()
        workspace.retainNotes(Set(library.notes.map(\.id)))
        persistWorkspace()
        reconcileSelection()
    }

    func addNotebook(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !name.isEmpty else { return }
        let notebook = Notebook(name: name)
        library.notebooks.append(notebook)
        scope = .notebook(notebook.id)
        save()
    }

    func renameNotebook(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !name.isEmpty,
              let index = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
        library.notebooks[index].name = name
        save()
    }

    func deleteNotebook(_ id: UUID) {
        guard isLoaded, !isReadOnly, library.notebooks.count > 1,
              let destination = library.notebooks.first(where: { $0.id != id }) else { return }
        for index in library.notes.indices where library.notes[index].notebookID == id {
            library.notes[index].notebookID = destination.id
        }
        library.notebooks.removeAll { $0.id == id }
        scope = .notebook(destination.id)
        save()
    }

    func attachFiles(_ files: [URL], to id: UUID) throws {
        guard isLoaded, !isReadOnly, let index = library.notes.firstIndex(where: { $0.id == id }),
              library.notes[index].deletedAt == nil else {
            throw JoplinImportError.invalid("Select an active note before adding attachments.")
        }
        var updated = try Attachments.adding(
            files: files, to: library.notes[index],
            directory: storage.url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
        )
        updated.recordRevision(of: library.notes[index])
        library.notes[index] = updated
        save()
    }

    func exportBackup(to folder: URL) throws {
        guard isLoaded else { throw LibraryError.invalidLibrary }
        try LibraryBackup.export(library, to: folder)
    }

    func exportVault(to folder: URL) throws {
        guard isLoaded else { throw LibraryError.invalidLibrary }
        try MarkdownVault.export(library, to: folder)
    }

    func connectSyncFolder(_ folder: URL) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        try bookmark.write(to: bookmarkURL, options: .atomic)
        syncFolder = folder
        syncFolderName = folder.lastPathComponent
        syncMessage = "Connected. Choose Sync Now to exchange offline changes."
    }

    func disconnectSyncFolder() {
        do {
            if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
            syncFolder = nil
            syncFolderName = nil
            syncMessage = "Disconnected. All local notes and attachments are still here."
        } catch { errorMessage = "Could not disconnect the folder: \(error.localizedDescription)" }
    }

    private func restoreSyncFolder() {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return }
        do {
            let bookmark = try Data(contentsOf: bookmarkURL)
            var stale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            guard !stale else { throw JoplinImportError.invalid("Folder permission expired. Connect the shared folder again.") }
            syncFolder = url
            syncFolderName = url.lastPathComponent
            syncMessage = "Shared folder connected. Notes are available offline."
        } catch {
            syncMessage = "Shared folder needs reconnection: \(error.localizedDescription)"
        }
    }

    func syncNow() {
        guard isLoaded, !isSyncing else { return }
        guard !isImportingJoplin else {
            syncMessage = "Finish importing before syncing."
            return
        }
        guard let folder = syncFolder else {
            syncMessage = "Connect the same iCloud Drive folder on both devices first."
            return
        }
        let snapshot = library
        let readOnly = isReadOnly
        let assets = storage.url.deletingLastPathComponent().appendingPathComponent("SyncAssets", isDirectory: true)
        isSyncing = true
        syncMessage = "Exchanging a verified snapshot..."
        Task {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer {
                if accessing { folder.stopAccessingSecurityScopedResource() }
                isSyncing = false
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if readOnly {
                        return try FolderSync.pull(snapshot, folder: folder, assets: assets)
                    }
                    return try FolderSync.synchronize(snapshot, folder: folder, assets: assets)
                }.value
                guard library == snapshot, syncFolder == folder else {
                    throw JoplinImportError.invalid("Notes changed while syncing. Your edits are safe; sync again to include them.")
                }
                try storage.save(result.library)
                library = result.library
                hasUnsavedChanges = false
                reconcileSelection()
                let when = Date().formatted(date: .omitted, time: .shortened)
                syncMessage = result.conflicts == 0 ? "Synced at \(when). Available offline."
                    : "Synced at \(when). \(result.conflicts) conflicts preserved; see #sync-conflict."
            } catch {
                syncMessage = "Sync not completed. Local notes are safe. \(error.localizedDescription)"
            }
        }
    }

    func importBackup(from folder: URL) throws {
        guard isLoaded, !isReadOnly else { throw LibraryError.invalidLibrary }
        let result = try LibraryBackup.imported(
            from: folder, importsDirectory: storage.url.deletingLastPathComponent().appendingPathComponent("Imports")
        )
        try commitJoplinImport(result)
    }

    #if os(macOS)
    func revealRecoveryCopies() {
        do {
            try FileManager.default.createDirectory(at: storage.recoveryDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([storage.recoveryDirectory])
        } catch { errorMessage = "Could not open recovery copies: \(error.localizedDescription)" }
    }

    func revealExtensions() {
        do {
            try FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([extensionsDirectory])
        } catch { errorMessage = "Could not open the extensions folder: \(error.localizedDescription)" }
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Connect an iCloud Drive Folder"
        panel.message = "Select the same dedicated folder on each device. Folio keeps local offline copies and exchanges immutable snapshots when you choose Sync Now. Start on one device, then let iCloud download the folder before connecting the next."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try connectSyncFolder(folder) }
        catch { errorMessage = "Could not connect the shared folder: \(error.localizedDescription)" }
    }

    func exportVault() {
        let panel = NSOpenPanel()
        panel.title = "Export an Open Markdown Folder"
        panel.message = "Creates ordinary Markdown/HTML files, notebook folders, metadata and original linked attachments. This is a portable snapshot, not live folder sync."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = "Folio Open Export " + Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        do {
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            try exportVault(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { errorMessage = "Open folder export failed: \(error.localizedDescription)" }
    }

    func addAttachments() {
        guard let id = selectedNoteID else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Images or Attachments"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do { try attachFiles(panel.urls, to: id) }
        catch { errorMessage = "Could not add attachments: \(error.localizedDescription)" }
    }

    func exportBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Save a Complete Folio Backup"
        panel.message = "A new timestamped folder will include all notes and original attachments. This is a backup, not live sync."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = "Folio Backup " + Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        do {
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            try exportBackup(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { errorMessage = "Backup failed: \(error.localizedDescription)" }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import a Folio Backup"
        panel.message = "Select a backup folder containing library.json. Its notes will be added without replacing current notes."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try importBackup(from: folder)
            importSummary = "Backup imported. Existing notes were preserved."
        } catch { errorMessage = "Backup import failed: \(error.localizedDescription)" }
    }

    func importMarkdown() {
        guard isLoaded, !isImportingJoplin, let notebookID = currentNotebookID else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Markdown or HTML Files"
        panel.message = "Linked local images and attachments in the same folder are copied into Folio. For shared parent resources, use Import Folder."
        panel.allowedContentTypes = [.plainText, .html, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let files = panel.urls
        let importsDirectory = storage.url.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true)
        isImportingJoplin = true
        Task {
            defer { isImportingJoplin = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DocumentFileImport.prepare(files: files, notebookID: notebookID, importsDirectory: importsDirectory)
                }.value
                try commitJoplinImport(result)
                importSummary = "Imported \(result.notes.count) documents and copied their local resources into Folio."
            } catch {
                errorMessage = "Import failed; no notes were imported: \(error.localizedDescription)"
            }
        }
    }

    func exportMarkdown(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.contentFormat == .html
            ? String(MarkdownFile.filename(for: note).dropLast(3)) + ".html" : MarkdownFile.filename(for: note)
        panel.allowedContentTypes = note.contentFormat == .html ? [.html] : [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MarkdownFile.export(note, to: url)
        } catch {
            errorMessage = "Could not export this note: \(error.localizedDescription)"
        }
    }

    func importJoplinFolder() {
        importJoplinFolder(includeHTML: false)
    }

    func importJoplinFolder(includeHTML: Bool) {
        guard isLoaded, !isImportingJoplin else { return }
        let panel = NSOpenPanel()
        panel.title = includeHTML ? "Import Markdown or HTML Folder" : "Import Joplin Markdown + Front Matter Folder"
        panel.message = "Subfolders become notebooks. Original images and attachments are copied to Folio without resizing."
        panel.prompt = "Import Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isImportingJoplin = true
        let importsDirectory = storage.url.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true)
        Task {
            defer { isImportingJoplin = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try JoplinImport.prepare(folder: folder, importsDirectory: importsDirectory, includeHTML: includeHTML)
                }.value
                try commitJoplinImport(result)
                importSummary = "Imported \(result.notes.count) notes into \(result.notebooks.count) notebooks. A copy of the export, including attachments, is stored in Folio's Imports folder."
            } catch {
                errorMessage = "Folder import failed; no notes were imported: \(error.localizedDescription)"
            }
        }
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([storage.url])
    }
    #endif

    func commitJoplinImport(_ result: JoplinImportResult) throws {
        guard !isReadOnly else { throw LibraryError.invalidLibrary }
        var candidate = library
        candidate.notebooks.append(contentsOf: result.notebooks)
        candidate.notes.append(contentsOf: result.notes)
        do {
            try storage.save(candidate)
        } catch {
            try JoplinImport.discardSnapshot(result.snapshotURL, after: error)
            throw error
        }
        library = candidate
        hasUnsavedChanges = false
        scope = .all
        query = ""
        selectedNoteID = result.notes.first?.id
    }

}
