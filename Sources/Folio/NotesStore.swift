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
    var branchPath: String?
}

struct NoteTextSummary {
    let excerpt: String
    let wordCount: Int
}

private struct CachedNoteText {
    let source: String
    let format: NoteFormat
    let summary: NoteTextSummary
}

@MainActor
private final class LibraryNavigationIndex {
    private let library: Library
    private var results: [Request: [Note]] = [:]
    private var queryCounts: [String: Int] = [:]
    lazy var notebookNames = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
    lazy var notesByID = Dictionary(uniqueKeysWithValues: library.notes.map { ($0.id, $0) })
    lazy var linkTargets = NoteLinks.targets(in: library)
    lazy var sidebarNotebooks: [NotebookBranch] = {
        let inbox = library.notebooks.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame }?.id
        return NotebookBranch.build(library.notebooks.filter { $0.id != inbox })
    }()
    lazy var branchesByPath: [String: NotebookBranch] = {
        var result: [String: NotebookBranch] = [:]
        for root in NotebookBranch.build(library.notebooks) { add(root, to: &result) }
        return result
    }()
    lazy var counts: Counts = {
        var result = Counts()
        for note in library.notes {
            guard note.deletedAt == nil else { result.trashed += 1; continue }
            result.active += 1
            if note.isPinned { result.pinned += 1 }
            result.notebooks[note.notebookID, default: 0] += 1
            for tag in Set(note.tags) { result.tags[tag, default: 0] += 1 }
        }
        return result
    }()
    private lazy var sortedNotes = library.notes.sorted {
        if $0.isPinned != $1.isPinned { return $0.isPinned }
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.id.uuidString < $1.id.uuidString
    }

    struct Counts {
        var active = 0
        var pinned = 0
        var trashed = 0
        var notebooks: [UUID: Int] = [:]
        var tags: [String: Int] = [:]
    }

    private struct Request: Hashable {
        let scope: NoteScope
        let query: String
        let savedQuery: String?
    }

    init(library: Library) { self.library = library }

    func notes(matching scope: NoteScope, query: String, savedQuery: String? = nil) -> [Note] {
        let request = Request(scope: scope, query: query, savedQuery: savedQuery)
        if let result = results[request] { return result }
        let parsed = NoteQuery(query)
        let saved = savedQuery.map(NoteQuery.init)
        let folderIDs: Set<UUID>?
        if case .folder(_, let ids) = scope { folderIDs = Set(ids) }
        else { folderIDs = nil }
        let result = sortedNotes.filter { note in
            let included = folderIDs.map { note.deletedAt == nil && $0.contains(note.notebookID) } ?? scope.includes(note)
            return included && parsed.matches(note, notebook: notebookNames[note.notebookID] ?? "") &&
                (saved?.matches(note, notebook: notebookNames[note.notebookID] ?? "") ?? true)
        }
        if results.count >= 8 { results.removeAll(keepingCapacity: true) }
        results[request] = result
        return result
    }

    func count(matching query: String) -> Int {
        if let count = queryCounts[query] { return count }
        let parsed = NoteQuery(query)
        let count = library.notes.reduce(0) { count, note in
            count + (note.deletedAt == nil && parsed.matches(note, notebook: notebookNames[note.notebookID] ?? "") ? 1 : 0)
        }
        if queryCounts.count >= 128 { queryCounts.removeAll(keepingCapacity: true) }
        queryCounts[query] = count
        return count
    }

    private func add(_ branch: NotebookBranch, to index: inout [String: NotebookBranch]) {
        index[branch.id] = branch
        for child in branch.children { add(child, to: &index) }
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var library = Library(notebooks: []) {
        didSet {
            cachedNavigation = nil
            if library.notes.count < oldValue.notes.count {
                let ids = Set(library.notes.map(\.id))
                cachedText = cachedText.filter { ids.contains($0.key) }
            }
        }
    }
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
    @Published var showingTemplates = false
    @Published var showingTasks = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncMessage = "Offline. No shared folder connected."
    @Published private(set) var extensions: [NoteExtension] = []
    @Published private(set) var isImportingJoplin = false
    @Published var importSummary: String? {
        didSet { if importSummary == nil { importReportURL = nil } }
    }
    @Published private(set) var importReportURL: URL?
    @Published private(set) var isLoaded = false
    @Published private(set) var hasUnsavedChanges = false
    #if os(macOS)
    @Published private(set) var shortcutBindings = ShortcutConfiguration.defaults
    @Published private(set) var shortcutsAvailable = true
    @Published private(set) var extensionConfiguration = ExtensionManagerConfiguration()
    @Published private(set) var extensionConfigurationAvailable = true
    @Published private(set) var extensionConfigurationError: String?
    @Published private(set) var pluginInspections: [PluginInspection] = []
    @Published private(set) var isPreparingPrint = false
    private var notePrinter: NotePrinter?
    var backupManager: BackupManager?
    #endif
    private let storage: LibraryStorage
    private let preferences: UserDefaults
    private var cachedNavigation: LibraryNavigationIndex?
    private var cachedText: [UUID: CachedNoteText] = [:]
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
        restoreSyncFolder()
        if !readOnly { reloadExtensions() }
        #if os(macOS)
        if !readOnly {
            backupManager = BackupManager(store: self, defaults: preferences)
        }
        #endif
    }

    var visibleNotes: [Note] {
        if case .smart = scope, activeSmartFolder == nil { return [] }
        return navigationIndex.notes(matching: resolvedScope, query: query, savedQuery: activeSmartFolder?.query)
    }

    private var resolvedScope: NoteScope {
        guard case .folder(let path, _) = scope else { return scope ?? .all }
        return .folder(path, navigationIndex.branchesByPath[path]?.descendants ?? [])
    }

    var navigationFolder: NotebookBranch? {
        let index = navigationIndex
        switch scope {
        case .notebook(let id):
            guard let name = index.notebookNames[id] else { return nil }
            return index.branchesByPath[name]
        case .folder(let path, _):
            return index.branchesByPath[path]
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
        return navigationIndex.notes(matching: .folder(folder.id, folder.descendants), query: query)
    }

    var selectedNote: Note? {
        selectedNoteID.flatMap { navigationIndex.notesByID[$0] }
    }

    var tags: [String] { navigationIndex.counts.tags.keys.sorted() }
    var sidebarNotebooks: [NotebookBranch] { navigationIndex.sidebarNotebooks }
    var noteLinkTargets: [String: UUID] { navigationIndex.linkTargets }

    func noteCount(in scope: NoteScope) -> Int {
        let counts = navigationIndex.counts
        switch scope {
        case .all, .smart: return counts.active
        case .pinned: return counts.pinned
        case .trash: return counts.trashed
        case .notebook(let id): return counts.notebooks[id, default: 0]
        case .tag(let tag): return counts.tags[tag, default: 0]
        case .folder(_, let ids): return Set(ids).reduce(0) { $0 + counts.notebooks[$1, default: 0] }
        }
    }

    func textSummary(for note: Note) -> NoteTextSummary {
        if let cached = cachedText[note.id], cached.source == note.body, cached.format == note.contentFormat {
            return cached.summary
        }
        let text = note.textContent
        let summary = NoteTextSummary(excerpt: text.split(whereSeparator: \.isNewline).joined(separator: " "),
                                      wordCount: text.split(whereSeparator: \.isWhitespace).count)
        cachedText[note.id] = CachedNoteText(source: note.body, format: note.contentFormat, summary: summary)
        return summary
    }

    private var navigationIndex: LibraryNavigationIndex {
        if let cachedNavigation { return cachedNavigation }
        let index = LibraryNavigationIndex(library: library)
        cachedNavigation = index
        return index
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
        navigationIndex.count(matching: folder.query)
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
            cachedText.removeAll()
            restoringWorkspace = true
            isLoaded = true
            hasUnsavedChanges = false
            selectedNoteID = visibleNotes.first?.id
            #if os(macOS)
            restoreWorkspace()
            reloadSmartFolders()
            reloadShortcuts()
            reloadExtensionConfiguration()
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

    @discardableResult func createFromTemplate(_ template: NoteTemplate) -> Bool {
        #if os(macOS)
        guard featureEnabled(.templates), templateChoices.contains(where: { $0.template == template }) else {
            errorMessage = "Enable the template chooser in Settings > Built-in Features and this template's pack in Community Extensions before using it."
            return false
        }
        #endif
        guard isLoaded, !isReadOnly, let notebookID = currentNotebookID else {
            errorMessage = "Open an editable notebook before creating a template note."
            return false
        }
        let now = Date()
        var tags = template.tags ?? []
        if case .tag(let tag) = scope { tags.append(tag) }
        let note = Note(notebookID: notebookID, title: template.render(template.title, date: now),
                        body: template.render(template.body, date: now), tags: tags,
                        isPinned: scope == .pinned, format: .markdown)
        var candidate = library
        candidate.notes.insert(note, at: 0)
        do { try storage.save(candidate) }
        catch {
            errorMessage = "Could not create the template note: \(error.localizedDescription)"
            return false
        }
        library = candidate
        hasUnsavedChanges = false
        if scope == .trash { scope = .all }
        if case .smart = scope { scope = .all }
        query = ""
        #if os(macOS)
        workspace.select(note.id)
        #endif
        selectedNoteID = note.id
        return true
    }

    var templateChoices: [TemplateChoice] {
        #if os(macOS)
        let packs = activeTemplatePacks
        #else
        let packs = extensions
        #endif
        return TemplateChoice.builtIn + packs.flatMap { pack in
            pack.templates.map { TemplateChoice(packID: pack.id, packName: pack.name, template: $0) }
        }
    }

    #if os(macOS)
    func printSelectedNote() {
        guard isLoaded, let note = selectedNote, !isPreparingPrint else {
            errorMessage = "Select a note and wait for any current print job to finish before printing."
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            errorMessage = "Open the Deltos note window before printing."
            return
        }
        do {
            let printer = try NotePrinter(note: note)
            notePrinter = printer
            isPreparingPrint = true
            Task {
                defer {
                    printer.close()
                    notePrinter = nil
                    isPreparingPrint = false
                }
                do {
                    try await printer.prepare()
                    let operation = try printer.makeOperation()
                    _ = await printer.run(operation, in: window)
                } catch { errorMessage = "Could not print the note: \(error.localizedDescription)" }
            }
        } catch { errorMessage = "Could not prepare the note for printing: \(error.localizedDescription)" }
    }

    func reloadExtensionConfiguration() {
        do {
            let candidate: ExtensionManagerConfiguration
            if let stored = preferences.object(forKey: ExtensionManagerConfiguration.preferenceKey) {
                guard let data = stored as? Data else {
                    throw ExtensionManagementError("The saved configuration is not valid data.")
                }
                candidate = try JSONDecoder().decode(ExtensionManagerConfiguration.self, from: data)
            } else {
                candidate = ExtensionManagerConfiguration()
            }
            try candidate.validate()
            extensionConfiguration = candidate
            extensionConfigurationAvailable = true
            extensionConfigurationError = nil
        } catch {
            extensionConfigurationAvailable = false
            extensionConfigurationError = "Could not load extension settings. Saved data is preserved; community template packs are inactive until settings are recovered or explicitly reset. \(error.localizedDescription)"
        }
        applyExtensionConfiguration()
    }

    func saveExtensionConfiguration(_ candidate: ExtensionManagerConfiguration) {
        guard isLoaded, !isReadOnly, extensionConfigurationAvailable else {
            errorMessage = "Open an editable library and recover or reset extension settings before changing them."
            return
        }
        do {
            try candidate.validate()
            let data = try JSONEncoder().encode(candidate)
            preferences.set(data, forKey: ExtensionManagerConfiguration.preferenceKey)
            extensionConfiguration = candidate
            applyExtensionConfiguration()
        } catch { errorMessage = "Could not save extension settings: \(error.localizedDescription)" }
    }

    func resetExtensionConfiguration() {
        guard isLoaded, !isReadOnly else {
            errorMessage = "Open an editable library before resetting extension settings."
            return
        }
        preferences.removeObject(forKey: ExtensionManagerConfiguration.preferenceKey)
        reloadExtensionConfiguration()
    }

    private func applyExtensionConfiguration() {
        if !featureEnabled(.templates) { showingTemplates = false }
        if !featureEnabled(.tasks) { showingTasks = false }
        refreshPluginInspections()
    }

    func refreshPluginInspections() {
        pluginInspections = extensionConfiguration.plugins.map { location in
            do {
                return PluginInspection(location: location, metadata: try PluginInspector.inspect(location.folder), error: nil)
            } catch {
                return PluginInspection(location: location, metadata: nil,
                                        error: "Could not read this plugin's metadata: \(error.localizedDescription)")
            }
        }
    }

    func shortcut(_ action: ShortcutAction) -> ShortcutBinding {
        shortcutBindings[action.rawValue] ?? action.defaultBinding
    }

    func reloadShortcuts() {
        do {
            if let stored = preferences.object(forKey: "keyboardShortcuts"), !(stored is Data) {
                throw ShortcutError("The saved shortcut configuration is not valid data.")
            }
            shortcutBindings = try ShortcutConfiguration.decode(preferences.data(forKey: "keyboardShortcuts"))
            shortcutsAvailable = true
        } catch {
            shortcutBindings = ShortcutConfiguration.defaults
            shortcutsAvailable = false
            errorMessage = "Could not load custom shortcuts. Defaults are active; your saved configuration has not been replaced. \(error.localizedDescription)"
        }
    }

    func saveShortcuts(_ bindings: [String: ShortcutBinding]) throws {
        guard shortcutsAvailable else { throw ShortcutError("Reset the unreadable configuration before saving new shortcuts.") }
        let data = try ShortcutConfiguration.encode(bindings)
        preferences.set(data, forKey: "keyboardShortcuts")
        shortcutBindings = bindings
    }

    func resetShortcuts() {
        preferences.removeObject(forKey: "keyboardShortcuts")
        shortcutBindings = ShortcutConfiguration.defaults
        shortcutsAvailable = true
    }
    #endif

    func openDailyNote(on date: Date = Date()) throws {
        #if os(macOS)
        guard featureEnabled(.dailyNotes) else {
            throw NoteWorkflowError("Daily notes are disabled. Enable them in Settings > Built-in Features.")
        }
        #endif
        guard isLoaded, !isReadOnly else { throw NoteWorkflowError("Open an editable library before creating a daily note.") }
        let path = (preferences.string(forKey: "dailyNotebook") ?? "Journal").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NoteWorkflowError("Choose a nonempty notebook path, such as Journal or Personal/Journal, in Settings > Editor.")
        }
        let title = TemplateChoice.daily.template.render("{{date}}", date: date)
        let notebooks = library.notebooks.filter { $0.name == path }.sorted { $0.id.uuidString < $1.id.uuidString }
        let notebook = notebooks.first ?? Notebook(name: path)
        let notebookIDs = Set(notebooks.map(\.id))
        let existing = library.notes.filter { notebookIDs.contains($0.notebookID) && $0.title == title }
            .sorted {
                if ($0.deletedAt == nil) != ($1.deletedAt == nil) { return $0.deletedAt == nil }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        if let note = existing.first {
            guard note.deletedAt == nil else {
                throw NoteWorkflowError("Today's note is in Trash. Restore it there before reopening it.")
            }
            openNoteInNewTab(note.id)
            return
        }
        let choiceID = preferences.string(forKey: "dailyTemplate") ?? TemplateChoice.daily.id
        guard let choice = templateChoices.first(where: { $0.id == choiceID }) else {
            throw NoteWorkflowError("Your daily-note template is unavailable. Reload its pack or choose another in Settings > Editor.")
        }
        let note = Note(notebookID: notebook.id, title: title,
                        body: choice.template.render(choice.template.body, date: date),
                        tags: (choice.template.tags ?? []) + ["daily"], format: .markdown)
        var candidate = library
        if !candidate.notebooks.contains(where: { $0.id == notebook.id }) { candidate.notebooks.append(notebook) }
        candidate.notes.insert(note, at: 0)
        try storage.save(candidate)
        library = candidate
        hasUnsavedChanges = false
        openNoteInNewTab(note.id)
    }

    func setTask(_ task: NoteTask, complete: Bool) {
        #if os(macOS)
        guard featureEnabled(.tasks) else {
            errorMessage = "Task overview is disabled. Markdown checkboxes remain editable in your notes."
            return
        }
        #endif
        guard isLoaded, !isReadOnly, let note = library.notes.first(where: { $0.id == task.noteID }) else {
            errorMessage = "The task's note is unavailable for editing."
            return
        }
        do {
            let body = try NoteTasks.setting(task, complete: complete, in: note)
            update(note.id) { $0.body = body }
        } catch { errorMessage = error.localizedDescription }
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
        } else if library.notebooks.contains(where: { $0.id == note.notebookID }) {
            scope = .notebook(note.notebookID)
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

    @discardableResult func addNotebook(name: String) -> Bool {
        do {
            let path = try NotebookManagement.validatedPath(name)
            guard !library.notebooks.contains(where: { $0.name.caseInsensitiveCompare(path) == .orderedSame }) else {
                throw NoteWorkflowError("A notebook already exists at that path.")
            }
            let notebook = Notebook(name: path)
            var candidate = library
            candidate.notebooks.append(notebook)
            try commitNotebookChange(candidate)
            scope = .notebook(notebook.id)
            return true
        } catch { errorMessage = "Could not create notebook: \(error.localizedDescription)"; return false }
    }

    @discardableResult func renameNotebook(_ id: UUID, name: String) -> Bool {
        do {
            let path = try NotebookManagement.validatedPath(name)
            guard let index = library.notebooks.firstIndex(where: { $0.id == id }) else {
                throw NoteWorkflowError("The notebook no longer exists.")
            }
            guard !library.notebooks.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(path) == .orderedSame }) else {
                throw NoteWorkflowError("A notebook already exists at that path.")
            }
            var candidate = library
            candidate.notebooks[index].name = path
            try commitNotebookChange(candidate)
            scope = .notebook(id)
            return true
        } catch { errorMessage = "Could not rename notebook: \(error.localizedDescription)"; return false }
    }

    @discardableResult func renameNotebookBranch(_ path: String, to name: String) -> Bool {
        do {
            try commitNotebookChange(NotebookManagement.renaming(library, branch: path, to: name))
            let destination = try NotebookManagement.validatedPath(name)
            if let folder = NotebookBranch.build(library.notebooks).lazy.compactMap({ $0.branch(at: destination) }).first {
                scope = .folder(folder.id, folder.descendants)
            }
            return true
        } catch { errorMessage = "Notebook change failed: \(error.localizedDescription)"; return false }
    }

    @discardableResult func moveNotes(_ ids: Set<UUID>, to path: String) -> Bool {
        do {
            try commitNotebookChange(NotebookManagement.movingNotes(ids, in: library, to: path))
            if let folder = NotebookBranch.build(library.notebooks).lazy.compactMap({ $0.branch(at: path) }).first {
                scope = .folder(folder.id, folder.descendants)
            }
            reconcileSelection()
            return true
        } catch { errorMessage = "Could not move notes: \(error.localizedDescription)"; return false }
    }

    private func commitNotebookChange(_ candidate: Library) throws {
        guard isLoaded, !isReadOnly, !isSyncing else {
            throw NoteWorkflowError("Open an editable library and wait for sync before reorganising notebooks.")
        }
        try storage.save(candidate)
        library = candidate
        hasUnsavedChanges = false
    }

    func acceptNotebookDrop(_ items: [String], on path: String) -> Bool {
        let notes = items.filter { $0.hasPrefix("deltos-note:") }
        if notes.count == items.count, !notes.isEmpty {
            let ids = Set(notes.compactMap { UUID(uuidString: String($0.dropFirst("deltos-note:".count))) })
            guard ids.count == notes.count else { errorMessage = "The dragged note identifiers are invalid."; return false }
            return moveNotes(ids, to: path)
        }
        if items.count == 1, let item = items.first, item.hasPrefix("deltos-folder:") {
            let source = String(item.dropFirst("deltos-folder:".count))
            let leaf = source.split(separator: "/").last.map(String.init) ?? source
            return renameNotebookBranch(source, to: path + "/" + leaf)
        }
        errorMessage = "Drag a Deltos note or one notebook branch onto a notebook."
        return false
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

    #if os(macOS)
    func importComposeAttachments(_ files: [URL], to id: UUID) throws -> Attachments.Imported {
        guard isLoaded, !isReadOnly, !isSyncing,
              let index = library.notes.firstIndex(where: { $0.id == id }),
              library.notes[index].deletedAt == nil, library.notes[index].contentFormat == .formatted else {
            throw JoplinImportError.invalid("Select an editable Compose note before adding attachments.")
        }
        let imported = try Attachments.importing(
            files: files, for: library.notes[index],
            directory: storage.url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
        )
        var candidate = library
        candidate.notes[index].importedRootURL = imported.resources.root
        candidate.notes[index].importedSourceURL = imported.resources.source
        do {
            // Persist resource ownership before an undoable editor insertion can reference it.
            try storage.save(candidate)
        } catch {
            try JoplinImport.discardSnapshot(imported.directory, after: error)
            throw error
        }
        library = candidate
        hasUnsavedChanges = false
        return imported
    }
    #endif

    func exportBackup(to folder: URL) throws {
        guard isLoaded else { throw LibraryError.invalidLibrary }
        try LibraryBackup.export(library, to: folder)
    }

    func exportVault(to folder: URL) throws {
        guard isLoaded else { throw LibraryError.invalidLibrary }
        try MarkdownVault.export(library, to: folder)
    }

    #if os(macOS)
    lazy var syncManager = SyncManager(defaults: preferences) { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.performFolderExchange()
    }

    var syncTransport: @Sendable (Library, URL, URL, Bool) async throws -> FolderSyncResult = { snapshot, folder, assets, readOnly in
        try await Task.detached(priority: .utility) {
            if readOnly { return try FolderSync.pull(snapshot, folder: folder, assets: assets) }
            return try FolderSync.synchronize(snapshot, folder: folder, assets: assets)
        }.value
    }

    var syncConflictNotes: [Note] {
        library.notes.filter { $0.tags.contains("sync-conflict") }.sorted {
            $0.displayTitle == $1.displayTitle ? $0.id.uuidString < $1.id.uuidString : $0.displayTitle < $1.displayTitle
        }
    }

    var syncConflictSummaries: [SyncConflictSummary] {
        let unresolved = Set(syncConflictNotes.map(\.id))
        var covered: Set<UUID> = []
        var summaries = (library.folderSync?.conflictSummaries ?? []).compactMap { summary -> SyncConflictSummary? in
            let ids = summary.variantIDs.filter { unresolved.contains($0) }
            guard !ids.isEmpty else { return nil }
            covered.formUnion(ids)
            return SyncConflictSummary(id: summary.id, variantIDs: ids, includesDeletion: summary.includesDeletion)
        }
        // Older snapshots only recorded tags. Keep these notes actionable too.
        summaries += syncConflictNotes.filter { !covered.contains($0.id) }.map {
            SyncConflictSummary(id: $0.id, variantIDs: [$0.id])
        }
        return summaries
    }

    func reviewSyncConflict(_ id: UUID) {
        guard let note = library.notes.first(where: { $0.id == id }) else { return }
        query = ""
        scope = note.deletedAt == nil ? .all : .trash
        openNote(id)
    }

    /// Resolution is intentionally nondestructive: reviewed variants remain separate,
    /// editable notes, with their original attachments and histories.
    func keepSyncConflictVariants(_ ids: Set<UUID>) throws {
        guard isLoaded, !isReadOnly, !isSyncing, !syncManager.isRunning else {
            throw NoteWorkflowError("Wait for folder exchange to finish and open an editable library before resolving conflicts.")
        }
        var candidate = library
        for index in candidate.notes.indices where ids.contains(candidate.notes[index].id) &&
            candidate.notes[index].tags.contains("sync-conflict") {
            candidate.notes[index].tags.removeAll { $0 == "sync-conflict" }
            candidate.notes[index].updatedAt = Date()
        }
        let unresolved = Set(candidate.notes.filter { $0.tags.contains("sync-conflict") }.map(\.id))
        let summaries = candidate.folderSync?.conflictSummaries?.compactMap { summary -> SyncConflictSummary? in
            let remaining = summary.variantIDs.filter { unresolved.contains($0) }
            return remaining.isEmpty ? nil : SyncConflictSummary(id: summary.id, variantIDs: remaining,
                                                                 includesDeletion: summary.includesDeletion)
        }
        candidate.folderSync?.conflictSummaries = summaries
        try storage.save(candidate)
        library = candidate
        hasUnsavedChanges = false
    }
    #endif

    private var syncDiskChangedExternally = false

    private var folderExchangeBusy: Bool {
        #if os(macOS)
        isSyncing || syncManager.isRunning
        #else
        isSyncing
        #endif
    }

    func connectSyncFolder(_ folder: URL) throws {
        guard isLoaded, !folderExchangeBusy else {
            throw JoplinImportError.invalid("Open your library and wait for the current folder exchange to finish before connecting.")
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        try validateCloudFolder(folder)
        #if os(macOS)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        try bookmark.write(to: bookmarkURL, options: .atomic)
        #if os(macOS)
        let changedFolder = syncFolder != folder
        #endif
        syncFolder = folder
        syncFolderName = folder.lastPathComponent
        #if os(macOS)
        syncManager.setConnected(true, newFolder: changedFolder)
        #endif
        syncMessage = "Folder connected. Choose Sync Now for local snapshot exchange. Cloud upload and delivery are managed by your provider and are not verified by Deltos."
    }

    func disconnectSyncFolder() {
        do {
            if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
            syncFolder = nil
            syncFolderName = nil
            #if os(macOS)
            syncManager.setConnected(false)
            #endif
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
            #if os(macOS)
            syncManager.setConnected(true)
            #endif
            syncMessage = "Folder connection restored. Local notes are available offline; cloud upload and delivery are not verified by Deltos."
        } catch {
            syncMessage = "Shared folder needs reconnection: \(error.localizedDescription)"
        }
    }

    func syncNow() {
        guard isLoaded else { return }
        guard syncFolder != nil else {
            syncMessage = "Connect the same dedicated cloud folder on both devices first. Keep its contents downloaded locally."
            return
        }
        #if os(macOS)
        syncManager.request()
        #else
        guard !isSyncing else { return }
        Task {
            guard !isSyncing else { return }
            do { try await performFolderExchange() }
            catch { /* performFolderExchange presents the failure without replacing the cache. */ }
        }
        #endif
    }

    private func performFolderExchange() async throws {
        guard isLoaded, !isImportingJoplin else {
            throw SyncFailure.deferred("Finish importing and open the library before syncing.")
        }
        guard !syncDiskChangedExternally else {
            throw SyncFailure.deferred("The library file changed outside Deltos during the last exchange. Preserve both versions, then restart Deltos before syncing again.")
        }
        guard let folder = syncFolder else { throw CancellationError() }
        let snapshot = library
        let assets = storage.url.deletingLastPathComponent().appendingPathComponent("SyncAssets", isDirectory: true)
        isSyncing = true
        syncMessage = "Exchanging a verified snapshot..."
        let accessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            isSyncing = false
        }
        do {
            let diskSnapshot: Data
            do { diskSnapshot = try Data(contentsOf: storage.url) }
            catch {
                throw SyncFailure.deferred("The local library file could not be checked. Save your notes and retry. \(error.localizedDescription)")
            }
            do { try validateCloudFolder(folder) }
            catch {
                throw SyncFailure.unavailable("The connected folder is not available locally. Reconnect it or keep it downloaded, then retry. \(error.localizedDescription)")
            }
            #if os(macOS)
            let result = try await syncTransport(snapshot, folder, assets, isReadOnly)
            #else
            let readOnly = isReadOnly
            let result = try await Task.detached(priority: .userInitiated) {
                if readOnly { return try FolderSync.pull(snapshot, folder: folder, assets: assets) }
                return try FolderSync.synchronize(snapshot, folder: folder, assets: assets)
            }.value
            #endif
            try Task.checkCancellation()
            guard syncFolder == folder else { throw CancellationError() }
            guard library == snapshot else {
                throw SyncFailure.deferred("Notes changed while syncing. Your edits are safe; sync again to include them. Scheduling, when enabled, will retry.")
            }
            guard let diskCurrent = try? Data(contentsOf: storage.url), diskCurrent == diskSnapshot else {
                syncDiskChangedExternally = true
                throw SyncFailure.deferred("The local library file changed or became unavailable during sync. No notes were replaced. Preserve both versions and restart Deltos before syncing again.")
            }
            try storage.save(result.library)
            library = result.library
            hasUnsavedChanges = false
            reconcileSelection()
            let when = Date().formatted(date: .omitted, time: .shortened)
            syncMessage = folderExchangeMessage(at: when, conflicts: result.conflicts)
        } catch {
            syncMessage = "Sync not completed. Local notes are safe. \(error.localizedDescription)"
            throw error
        }
    }

    func folderExchangeMessage(at time: String, conflicts: Int) -> String {
        let operation = isReadOnly ? "Downloaded snapshots read locally" : "Snapshot exchange completed locally"
        let conflictMessage = conflicts == 0 ? "" : " \(conflicts) conflicts preserved; see #sync-conflict."
        return "\(operation) at \(time).\(conflictMessage) Cloud upload and delivery are not verified by Deltos."
    }

    func validateCloudFolder(_ folder: URL) throws {
        guard folder.isFileURL,
              try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw JoplinImportError.invalid("Choose an existing, locally downloaded folder managed by your cloud provider.")
        }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let local = storage.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard root != "/", root != local, !root.hasPrefix(local + "/"), !local.hasPrefix(root + "/") else {
            throw JoplinImportError.invalid("Choose a dedicated cloud folder outside Deltos's local library storage, not that storage or one of its parent folders.")
        }
    }

    @discardableResult
    func exportDatedBackup(to parent: URL, on date: Date = Date()) throws -> URL {
        guard isLoaded, !isReadOnly, !isSyncing else {
            throw JoplinImportError.invalid("Open an editable library and wait for folder exchange to finish before exporting a backup.")
        }
        let accessing = parent.startAccessingSecurityScopedResource()
        defer { if accessing { parent.stopAccessingSecurityScopedResource() } }
        try validateCloudFolder(parent)
        let name = "Deltos Backup " + date.ISO8601Format().replacingOccurrences(of: ":", with: "-") + " " + UUID().uuidString
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: parent, options: .forMerging, error: &coordinationError) { coordinated in
            result = Result {
                try LibraryBackup.export(library, to: coordinated.appendingPathComponent(name, isDirectory: true))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw JoplinImportError.invalid("The backup folder could not be coordinated. Retry once it is available locally.") }
        try result.get()
        return destination
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
        panel.title = "Connect a Cloud Folder"
        panel.message = "Choose a dedicated, locally downloaded folder in Dropbox, OneDrive, Google Drive, iCloud Drive or another provider's Mac app. Deltos exchanges snapshots manually; the provider handles upload. Start on one Mac and wait for delivery before connecting the next. Provider delivery is experimental and unverified."
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
        let name = "Deltos Open Export " + Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
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
        panel.title = "Choose Where to Save a Complete Deltos Backup"
        panel.message = "Choose a local folder or a downloaded Dropbox, OneDrive, Google Drive or iCloud folder. A new dated copy includes notes, history and original attachments. This is a manual backup, not scheduled backup or live sync. Deltos cannot confirm cloud upload."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try exportDatedBackup(to: parent)
            importSummary = "Complete backup saved locally. Check your cloud provider for upload completion. Keep an independent backup: cloud sync can propagate deletions."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { errorMessage = "Backup failed: \(error.localizedDescription)" }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import a Deltos Backup"
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
        panel.message = "Linked local images and attachments in the same folder are copied into Deltos. For shared parent resources, use Import Folder."
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
                importSummary = "Imported \(result.notes.count) documents and copied their local resources into Deltos."
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

    func importJoplinArchive() {
        guard isLoaded, !isReadOnly, !isImportingJoplin, !isSyncing else { return }
        isImportingJoplin = true
        let panel = NSOpenPanel()
        panel.title = "Import Joplin JEX Archive"
        panel.message = "Export JEX from Joplin after downloading attachments and decrypting/unlocking notes. Existing Deltos notes are preserved."
        panel.allowedContentTypes = [UTType(filenameExtension: "jex") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let archive = panel.url else {
            isImportingJoplin = false
            return
        }
        let imports = storage.url.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true)
        Task {
            defer { isImportingJoplin = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try JexImport.prepare(archive: archive, importsDirectory: imports)
                }.value
                try commitJoplinImport(result.imported)
                importReportURL = result.imported.snapshotURL.appendingPathComponent("import-report.json")
                importSummary = result.report.summary
            } catch {
                errorMessage = "JEX import failed; no notes were imported: \(error.localizedDescription)"
            }
        }
    }

    func importJoplinFolder(includeHTML: Bool) {
        guard isLoaded, !isImportingJoplin else { return }
        let panel = NSOpenPanel()
        panel.title = includeHTML ? "Import Markdown or HTML Folder" : "Import Joplin Markdown + Front Matter Folder"
        panel.message = "Subfolders become notebooks. Original images and attachments are copied to Deltos without resizing."
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
                importSummary = "Imported \(result.notes.count) notes into \(result.notebooks.count) notebooks. A copy of the export, including attachments, is stored in Deltos's Imports folder."
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
        do {
            guard isLoaded, !isReadOnly else { throw LibraryError.invalidLibrary }
            var candidate = library
            candidate.notebooks.append(contentsOf: result.notebooks)
            candidate.notes.append(contentsOf: result.notes)
            try storage.save(candidate)
            library = candidate
        } catch {
            try JoplinImport.discardSnapshot(result.snapshotURL, after: error)
            throw error
        }
        hasUnsavedChanges = false
        scope = .all
        query = ""
        selectedNoteID = result.notes.first?.id
    }

}
