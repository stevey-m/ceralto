import NotesCore
import SwiftUI

enum FolioCommand: String, CaseIterable, Identifiable {
    case newNote, newMarkdown, newNotebook, find, save, back, forward, closeTab
    case toggleFolders, toggleNotes, focus, importFiles, importJoplin, exportNote, exportVault
    case backup, importBackup, sync, revealLibrary, reloadTemplates
    case reference, closeReference
    case revealRecovery
    case newSmartFolder
    case today, templates, tasks, printNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newNote: "New Note"
        case .newMarkdown: "New Markdown Source Note"
        case .newNotebook: "New Notebook"
        case .find: "Find Across All Notes"
        case .save: "Save"
        case .back: "Back"
        case .forward: "Forward"
        case .closeTab: "Close Current Tab"
        case .toggleFolders: "Toggle Main Folders"
        case .toggleNotes: "Toggle Subtopics and Notes"
        case .focus: "Toggle Focused Writing"
        case .importFiles: "Import Markdown or HTML Files..."
        case .importJoplin: "Import Joplin Folder..."
        case .exportNote: "Export Current Note..."
        case .exportVault: "Export Open Markdown Folder..."
        case .backup: "Export Complete Backup..."
        case .importBackup: "Import Deltos Backup..."
        case .sync: "Sync Now"
        case .revealLibrary: "Show Library in Finder"
        case .reloadTemplates: "Reload Template Packs"
        case .reference: "Show Current Note as Reference"
        case .closeReference: "Close Reference Pane"
        case .revealRecovery: "Show Local Recovery Copies"
        case .newSmartFolder: "New Smart Folder from Current Search..."
        case .today: "Open Today's Note"
        case .templates: "Choose a Template..."
        case .tasks: "Show Tasks..."
        case .printNote: "Print Current Note..."
        }
    }

    @MainActor func shortcut(in store: NotesStore) -> String {
        if self == .printNote { return "⌘P" }
        guard let action = ShortcutAction.allCases.first(where: { $0.command == self }) else { return "" }
        let binding = store.shortcut(action)
        return binding.key.isEmpty ? "" : binding.label
    }

    static func matching(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return allCases.filter { command in
            terms.allSatisfy { command.title.localizedStandardContains(String($0)) }
        }
    }

    @MainActor func unavailableReason(in store: NotesStore) -> String? {
        if self == .revealLibrary || self == .revealRecovery { return nil }
        guard store.isLoaded else { return "Open your library first" }
        let feature: BuiltInFeature?
        switch self {
        case .today: feature = .dailyNotes
        case .templates: feature = .templates
        case .tasks: feature = .tasks
        default: feature = nil
        }
        if let feature, !store.featureEnabled(feature) {
            return "Enable \(feature.name) in Settings > Built-in Features"
        }
        switch self {
        case .printNote:
            if store.isPreparingPrint { return "A print job is already open" }
            return store.selectedNote == nil ? "Select a note first" : nil
        case .back: return store.workspace.canGoBack ? nil : "No earlier document"
        case .forward: return store.workspace.canGoForward ? nil : "No later document"
        case .closeTab, .exportNote, .reference: return store.selectedNote == nil ? "Select a note first" : nil
        case .closeReference: return store.referenceNote == nil ? "No reference pane open" : nil
        case .today, .templates: return store.isReadOnly ? "This library is read-only" : nil
        case .newSmartFolder:
            if !store.smartFoldersAvailable { return "Reload saved smart folders first" }
            if store.scope == .trash { return "Smart folders search active notes, not Trash" }
            return store.searchError
        case .sync:
            if store.isSyncing { return "Sync already in progress" }
            if store.isImportingJoplin { return "Import in progress" }
            return store.syncFolderName == nil ? "Connect a cloud folder first" : nil
        case .importJoplin, .importFiles, .importBackup:
            return store.isImportingJoplin ? "Import in progress" : nil
        default: return nil
        }
    }
}

extension NotesStore {
    func perform(_ command: FolioCommand) {
        if let reason = command.unavailableReason(in: self) {
            errorMessage = "\(command.title): \(reason)."
            return
        }
        switch command {
        case .newNote: createNote()
        case .newMarkdown: createMarkdownNote()
        case .newNotebook: notebookDraft = NotebookDraft()
        case .find: showingFinder = true
        case .save: save()
        case .back: navigateBack()
        case .forward: navigateForward()
        case .closeTab: if let selectedNoteID { closeTab(selectedNoteID) }
        case .toggleFolders: preferencesToggle("showNotebookPane")
        case .toggleNotes: preferencesToggle("showNoteListPane")
        case .focus:
            let folders = preferencesValue("showNotebookPane")
            let notes = preferencesValue("showNoteListPane")
            setPaneVisibility(folders: !folders && !notes, notes: !folders && !notes)
        case .importFiles: importMarkdown()
        case .importJoplin: importJoplinFolder()
        case .exportNote: if let selectedNote { exportMarkdown(selectedNote) }
        case .exportVault: exportVault()
        case .backup: exportBackup()
        case .importBackup: importBackup()
        case .sync: syncNow()
        case .revealLibrary: revealLibrary()
        case .reloadTemplates: reloadExtensions()
        case .reference: showReference(selectedNoteID)
        case .closeReference: showReference(nil)
        case .revealRecovery: revealRecoveryCopies()
        case .newSmartFolder: draftSmartFolder()
        case .today:
            do { try openDailyNote() }
            catch { errorMessage = "Could not open today's note: \(error.localizedDescription)" }
        case .templates: showingTemplates = true
        case .tasks: showingTasks = true
        case .printNote: printSelectedNote()
        }
    }
}

struct CommandPalette: View {
    let onSelect: (FolioCommand) -> Void
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selection: FolioCommand?
    @FocusState private var searching: Bool

    private var commands: [FolioCommand] { FolioCommand.matching(query) }
    private var available: [FolioCommand] { commands.filter { $0.unavailableReason(in: store) == nil } }
    private var selected: FolioCommand? {
        if let selection, available.contains(selection) { return selection }
        return available.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searching)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(commands) { command in
                        let reason = command.unavailableReason(in: store)
                        Button { run(command) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title)
                                    if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(command.shortcut(in: store)).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(selected == command ? Color.accentColor.opacity(0.13) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(reason != nil)
                        .id(command)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if commands.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .onChange(of: selection) { _, value in
                    if let value { proxy.scrollTo(value) }
                }
            }
            Divider()
            HStack {
                Text("↑ ↓ to choose · Return to run · Esc to close").foregroundStyle(.secondary)
                Spacer()
                Button("Run", action: run).disabled(selected == nil)
            }.font(.caption).padding(14)
        }
        .frame(width: 580, height: 500)
        .background(.background)
        .folioAppearance()
        .onAppear { searching = true }
        .onChange(of: query) { _, _ in selection = available.first }
    }

    private func move(_ step: Int) {
        guard !available.isEmpty else { return }
        let index = available.firstIndex { $0 == selected } ?? 0
        selection = available[min(max(index + step, 0), available.count - 1)]
    }

    private func run() {
        if let selected { run(selected) }
    }

    private func run(_ command: FolioCommand) {
        onSelect(command)
        dismiss()
    }
}
