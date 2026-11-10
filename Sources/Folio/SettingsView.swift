import AppKit
import NotesCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", editor = "Editor"
    case files = "Files & Backups", sync = "Cloud Folders", extensions = "Community Extensions"
    case features = "Built-in Features"
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
        case .features: "switch.2"
        case .shortcuts: "keyboard"
        }
    }

    var keywords: String {
        switch self {
        case .general: "version releases updates help github source license contributors note list preview dates"
        case .appearance: "theme system light dark dracula accent gold blue purple green rose font text size images width panes layout"
        case .editor: "new note default format compose markdown source spelling spellcheck daily journal today templates"
        case .files: "library storage location import export joplin markdown html attachments backup restore history privacy encryption trash"
        case .sync: "icloud dropbox onedrive google drive cloud folder connect disconnect sync offline ipad refresh snapshots conflicts backup"
        case .extensions: "templates packs plugins api community reload install joplin obsidian compatibility inspect folders"
        case .features: "core plugins built in optional tools daily notes templates tasks enable disable"
        case .shortcuts: "keyboard shortcuts hotkeys commands palette tabs back forward navigation capture finder search save focus"
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
    @AppStorage("dailyNotebook") private var dailyNotebook = "Journal"
    @AppStorage("dailyTemplate") private var dailyTemplate = TemplateChoice.daily.id

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
            Section("Daily notes") {
                TextField("Notebook path", text: $dailyNotebook)
                Picker("Template", selection: $dailyTemplate) {
                    if !store.templateChoices.contains(where: { $0.id == dailyTemplate }) {
                        Text("Unavailable template: \(dailyTemplate)").tag(dailyTemplate)
                    }
                    ForEach(store.templateChoices) { choice in
                        Text("\(choice.packName) / \(choice.template.name)").tag(choice.id)
                    }
                }
                Text("Open Today's Note reuses the YYYY-MM-DD title in this notebook, using your Mac's local date. The notebook is created if needed. If you rename the note or notebook, update your workflow or this path. Daily notes use Markdown source; no reminders or background scheduling.")
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
                Button("Show Local Recovery Copies...", action: store.revealRecoveryCopies)
                Text("Before opening an existing Mac library for editing, Folio keeps its first validated copy of the day. The last seven opening days are retained. These JSON copies contain notes and history, but not attachment files or unsaved drafts. They are not complete backups.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To recover a whole library copy, quit Folio, preserve the current library.json, then copy the chosen recovery file to that location as library.json. Attachments must still exist in their original locations. Never replace the file while Folio is running.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Complete Backup...", action: store.exportBackup)
                    .disabled(!store.isLoaded)
                Button("Import Folio Backup...", action: store.importBackup)
                    .disabled(!store.isLoaded)
                Text("Complete backups include notes, history and original attachments. Import adds notes without replacing current ones. Back up regularly or use Time Machine; scheduled backups are not implemented.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Note history retains up to 20 checkpoints, captured at most once every five minutes. Open Note actions > Note History to restore one. Trash is kept until you delete notes permanently; no automatic deletion is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .sync:
            Section("Cloud folder exchange (experimental)") {
                Text("Choose a dedicated folder managed by Dropbox, OneDrive, Google Drive, iCloud Drive or another provider's Mac app. Install and sign in to that app separately, and keep the entire folder downloaded or available offline.")
                    .foregroundStyle(.secondary)
                LabeledContent("Connected folder", value: store.syncFolderName ?? "Not connected")
                Text(store.syncMessage).textSelection(.enabled)
                Button("Connect Cloud Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing)
                Button(store.isSyncing ? "Syncing..." : "Sync Now", action: store.syncNow)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
                Button("Disconnect", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
            }
            Section("Backups are separate from sync") {
                Button("Export Dated Complete Backup...", action: store.exportBackup)
                    .disabled(!store.isLoaded || store.isReadOnly || store.isSyncing)
                Button("Import Folio Backup...", action: store.importBackup).disabled(!store.isLoaded)
                Text("Choose a separate backup location, ideally outside the sync folder or with another provider. Each manual backup creates a new dated copy of notes, history and original attachments. Nothing is overwritten or automatically pruned. No scheduled backups or direct cloud account sign-in are implemented.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("A local save does not confirm upload. Check the provider's app before relying on another device. Cloud deletion can remove synced backups too; keep an independent copy. Files are readable, not end-to-end encrypted by Folio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Offline reader & limitations") {
                Text("The iPad reader's existing iCloud path remains experimental. Third-party Files-provider access on iPad is not validated; selecting a Mac cloud folder does not enable direct iPad account access. Xcode signing and installation are required.")
                Text("Manual snapshot exchange, not continuous sync. Dropbox, OneDrive, Google Drive and physical-device iCloud delivery are unverified. Full snapshots are retained indefinitely, including earlier deleted notes. Do not move the live library.json into a cloud folder.")
                    .foregroundStyle(.secondary)
            }
        case .extensions:
            CommunityExtensionsSettings()
            Section("Documentation") {
                Button("Extension API & Example") { openProject("blob/main/EXTENSIONS.md") }
            }
        case .features:
            BuiltInFeaturesSettings()
        case .shortcuts:
            ShortcutSettings(bindings: store.shortcutBindings)
            Section("Keyboard shortcuts") {
                shortcut("Save Quick Capture", "⌘Return")
                shortcut("Search this collection", "⌘F")
                shortcut("Bold / Italic in Compose", "⌘B / ⌘I")
                shortcut("Back from image", "Esc")
                Text("These contextual editing shortcuts are fixed. Application shortcuts above work while Folio is active; a global capture hotkey is not implemented.")
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
