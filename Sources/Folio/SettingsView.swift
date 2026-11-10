import AppKit
import NotesCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", editor = "Editor"
    case files = "Files & Backups", sync = "iCloud", extensions = "Extensions"
    case shortcuts = "Keyboard Shortcuts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .editor: "square.and.pencil"
        case .files: "externaldrive"
        case .sync: "icloud"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "keyboard"
        }
    }

    var keywords: String {
        switch self {
        case .general: "version releases updates help github source license contributors note list preview dates"
        case .appearance: "theme system light dark dracula accent gold blue purple green rose font text size images width panes layout"
        case .editor: "new note default format compose markdown source spelling spellcheck"
        case .files: "library storage location import export joplin markdown html attachments backup restore history privacy encryption trash"
        case .sync: "icloud folder connect disconnect sync offline ipad refresh snapshots conflicts"
        case .extensions: "templates packs plugins api community reload install"
        case .shortcuts: "keyboard shortcuts hotkeys commands capture finder search save focus"
        }
    }

    static func matching(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return allCases.filter { section in
            terms.allSatisfy { (section.rawValue + " " + section.keywords).localizedStandardContains($0) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var selection: SettingsSection? = .general
    @ViewState private var query = ""
    @AppStorage("defaultNoteFormat") private var defaultFormat = NoteFormat.formatted.rawValue
    @AppStorage("composeSpellChecking") private var spellChecking = true
    @AppStorage("noteListPreviewLines") private var previewLines = 2
    @AppStorage("noteListShowDates") private var showDates = true

    private var matches: [SettingsSection] { SettingsSection.matching(query) }

    init(section: SettingsSection = .general) {
        _selection = ViewState(initialValue: section)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                TextField("Search settings", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search settings")
                    .padding(.horizontal, 12).padding(.top, 16)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(matches) { section in
                            Button { selection = section } label: {
                                Label(section.rawValue, systemImage: section.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background {
                                if selection == section {
                                    RoundedRectangle(cornerRadius: 7).fill(.tint.opacity(0.15))
                                }
                            }
                            .accessibilityAddTraits(selection == section ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 210)
            .background(.background)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let selection, matches.contains(selection) {
                    Text(selection.rawValue).font(.title2.weight(.semibold)).padding(24)
                    if selection == .appearance {
                        AppearanceSettings()
                    } else {
                        Form {
                            sectionContent(selection)
                        }
                        .formStyle(.grouped)
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = store.errorMessage {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .textSelection(.enabled).foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss") { store.errorMessage = nil }
                    }.padding()
                }
                if let summary = store.importSummary {
                    HStack {
                        Text(summary).textSelection(.enabled)
                        Spacer()
                        Button("OK") { store.importSummary = nil }
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 620, idealHeight: 680)
        .onChange(of: query) { _, _ in
            if selection.map({ !matches.contains($0) }) ?? true { selection = matches.first }
        }
        .folioAppearance()
    }

    @ViewBuilder private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            Section("Folio") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Source build")
                Text("A native notebook. Your notes stay on your device. MIT licensed, with no Folio account or subscription.")
                    .foregroundStyle(.secondary)
                Button("View Releases & Downloads") { openProject("releases") }
                Text("Updates are downloaded and installed manually. Folio does not check for updates in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Help & Documentation") { openProject("blob/main/README.md") }
                Button("Contribute on GitHub") { openProject("blob/main/CONTRIBUTING.md") }
            }
            Section("Note list") {
                Picker("Preview lines", selection: $previewLines) {
                    Text("Titles only").tag(0)
                    ForEach(1...3, id: \.self) { Text("\($0) \($0 == 1 ? "line" : "lines")").tag($0) }
                }
                Toggle("Show dates in the note list", isOn: $showDates)
            }
        case .editor:
            Section("New notes") {
                Picker("Default format", selection: $defaultFormat) {
                    Text("Native Compose (Markdown underneath)").tag(NoteFormat.formatted.rawValue)
                    Text("Markdown source").tag(NoteFormat.markdown.rawValue)
                }
                Text("Applies to new notes only. Imported notes, existing notes and template packs keep their format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing") {
                Toggle("Check spelling in Compose", isOn: $spellChecking)
                Text("Uses macOS spelling locally. Automatic spelling correction stays off. Use Appearance for font, text size and reading width.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .files:
            Section("Local library") {
                Text(store.libraryURL.deletingLastPathComponent().path).textSelection(.enabled)
                    .font(.callout.monospaced())
                Button("Show Library in Finder", action: store.revealLibrary)
                Text("Do not move the working library into a shared folder. Notes, drafts and attachments are not encrypted by Folio; use FileVault and device protection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Import & export") {
                Button("Import Markdown or HTML Files...", action: store.importMarkdown)
                Button("Import Joplin Export Folder...", action: store.importJoplinFolder)
                Button("Export Open Markdown Folder...", action: store.exportVault)
                Text("Open-folder export is a portable snapshot with original attachments, not a live Markdown vault.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!store.isLoaded || store.isImportingJoplin)
            Section("Backups & recovery") {
                Button("Export Complete Backup...", action: store.exportBackup)
                Button("Import Folio Backup...", action: store.importBackup)
                Text("Complete backups include notes, history and original attachments. Import adds notes without replacing current ones. Back up regularly or use Time Machine; scheduled backups are not implemented.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Note history retains up to 20 checkpoints, captured at most once every five minutes. Open Note actions > Note History to restore one. Trash is kept until you delete notes permanently; no automatic deletion is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!store.isLoaded)
        case .sync:
            Section("iCloud Drive folder") {
                LabeledContent("Connected folder", value: store.syncFolderName ?? "Not connected")
                Text(store.syncMessage).textSelection(.enabled)
                Button("Connect iCloud Drive Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing)
                Button(store.isSyncing ? "Syncing..." : "Sync Now", action: store.syncNow)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
                Button("Disconnect", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
            }
            Section("Offline reader & limitations") {
                Text("On iPad, connect the same folder and refresh to keep a local read-only copy. Xcode signing and installation are required.")
                Text("Experimental manual snapshot exchange, not continuous sync. Physical-device iCloud delivery is unverified. Full snapshots are retained indefinitely, including earlier deleted notes, and are not end-to-end encrypted by Folio.")
                    .foregroundStyle(.secondary)
            }
        case .extensions:
            Section("Template packs") {
                Button("Open Extensions Folder", action: store.revealExtensions)
                Button("Reload Template Packs", action: store.reloadExtensions)
                if store.extensions.isEmpty {
                    Text("No template packs installed. Place a pack folder containing extension.json in Extensions, then reload.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.extensions) { pack in
                    LabeledContent(pack.name, value: "\(pack.templates.count) templates")
                }
                Text("Create notes using File > New from Template. API v1 supports local data-only templates, not executable plugins or Obsidian plugin compatibility.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Extension API & Example") { openProject("blob/main/EXTENSIONS.md") }
            }
        case .shortcuts:
            Section("Keyboard shortcuts") {
                shortcut("New note", "⌘N")
                shortcut("New notebook", "⇧⌘N")
                shortcut("Quick Capture (while Folio is active)", "⇧⌘Space")
                shortcut("Save Quick Capture", "⌘Return")
                shortcut("Find across all notes", "⌘K")
                shortcut("Search this collection", "⌘F")
                shortcut("Save", "⌘S")
                shortcut("Sync now", "⇧⌘R")
                shortcut("Toggle main folders", "⌥⌘S")
                shortcut("Toggle subtopics and notes", "⌥⌘L")
                shortcut("Bold / Italic in Compose", "⌘B / ⌘I")
                shortcut("Back from image", "Esc")
                Text("Reference only; shortcut remapping and global capture hotkeys are not implemented. Menu items show other available shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .appearance:
            EmptyView()
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).monospaced() }
    }

    private func openProject(_ path: String) {
        guard let url = URL(string: "https://github.com/stevey-m/folio/" + path), NSWorkspace.shared.open(url) else {
            store.errorMessage = "Could not open the Folio project page in your browser."
            return
        }
    }
}
