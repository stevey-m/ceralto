import AppKit
import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var store = NotesStore()
    @StateObject private var markdown = LiveMarkdownStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.liveMarkdown) private var focusedMarkdown

    var body: some Scene {
        Window("Deltos", id: "library") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear {
                    delegate.store = store; delegate.markdown = markdown
                    store.backupManager?.start()
                    store.syncManager.start()
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { openWindow(id: "library"); store.perform(.newNote) }
                    .keyboardShortcut(store.shortcut(.newNote).keyboardShortcut)
                    .disabled(!store.isLoaded)
                Button("New Markdown Source Note") { openWindow(id: "library"); store.perform(.newMarkdown) }
                    .disabled(!store.isLoaded)
                Menu("New from Template") {
                    Button("Choose a Template...") { openWindow(id: "library"); store.perform(.templates) }
                        .keyboardShortcut(store.shortcut(.templates).keyboardShortcut)
                    Divider()
                    if store.activeTemplatePacks.isEmpty { Text("No enabled template packs") }
                    ForEach(store.activeTemplatePacks) { pack in
                        Menu(pack.name) {
                            ForEach(pack.templates) { template in
                                Button(template.name) { store.createFromTemplate(template) }
                            }
                        }
                    }
                    Divider()
                    Button("Open Extensions Folder", action: store.revealExtensions)
                    Button("Reload Extensions", action: store.reloadExtensions)
                }.disabled(FolioCommand.templates.unavailableReason(in: store) != nil)
                Button("Quick Capture") { capture() }
                    .keyboardShortcut(store.shortcut(.capture).keyboardShortcut)
                    .disabled(!store.isLoaded)
                Button("New Notebook") { store.notebookDraft = NotebookDraft() }
                    .keyboardShortcut(store.shortcut(.newNotebook).keyboardShortcut)
                    .disabled(!store.isLoaded)
                Button("New Smart Folder...") { store.perform(.newSmartFolder) }
                    .disabled(FolioCommand.newSmartFolder.unavailableReason(in: store) != nil)
                Divider()
                Button("Import Markdown or HTML Files...", action: store.importMarkdown)
                    .keyboardShortcut(store.shortcut(.importFiles).keyboardShortcut)
                    .disabled(!store.isLoaded)
                Button("Open Live Markdown Folder...") {
                    openWindow(id: "live-markdown")
                    markdown.chooseFolder(avoiding: store.libraryURL)
                }
                Button("Reopen Last Markdown Folder") {
                    openWindow(id: "live-markdown")
                    markdown.reopenLast(avoiding: store.libraryURL)
                }.disabled(!markdown.hasRememberedFolder)
                Button("Import Joplin Folder...", action: store.importJoplinFolder)
                    .disabled(!store.isLoaded || store.isImportingJoplin)
                Button("Import Joplin JEX Archive...", action: store.importJoplinArchive)
                    .disabled(!store.isLoaded || store.isImportingJoplin || store.isSyncing)
                Button("Import Markdown or HTML Folder...") { store.importJoplinFolder(includeHTML: true) }
                    .disabled(!store.isLoaded || store.isImportingJoplin)
                Button("Export Note...") {
                    if let note = store.selectedNote { store.exportMarkdown(note) }
                }
                .keyboardShortcut(store.shortcut(.exportNote).keyboardShortcut)
                .disabled(store.selectedNote == nil)
                Divider()
                Button("Add Images or Attachments...", action: store.addAttachments)
                    .keyboardShortcut(store.shortcut(.addAttachments).keyboardShortcut)
                    .disabled(store.selectedNote == nil || store.selectedNote?.deletedAt != nil)
                Button("Export Complete Backup...", action: store.exportBackup)
                    .disabled(!store.isLoaded || store.isImportingJoplin || store.isSyncing)
                Button("Export Encrypted Complete Backup...") { store.encryptedBackup(exporting: true) }
                    .disabled(!store.isLoaded || store.isImportingJoplin || store.isSyncing || store.isProcessingEncryptedBackup)
                Button("Import Encrypted Backup...") { store.encryptedBackup(exporting: false) }
                    .disabled(store.isImportingJoplin || store.isSyncing || store.isProcessingEncryptedBackup)
                    .disabled(!store.isLoaded)
                Button("Export Open Markdown Folder...", action: store.exportVault)
                    .disabled(!store.isLoaded)
                Button("Import Deltos Backup...", action: store.importBackup)
                    .disabled(!store.isLoaded)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    if let focusedMarkdown { focusedMarkdown.save() }
                    else { store.perform(.save) }
                }
                    .keyboardShortcut(store.shortcut(.save).keyboardShortcut)
                    .disabled(focusedMarkdown == nil && !store.isLoaded)
                Button("Show Library in Finder", action: store.revealLibrary)
                Button("Show Local Recovery Copies...", action: store.revealRecoveryCopies)
                Divider()
                Button("Connect Cloud Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing)
                Button("Sync Now", action: store.syncNow)
                    .keyboardShortcut(store.shortcut(.sync).keyboardShortcut)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
                Button("Disconnect Shared Folder", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button(store.isPreparingPrint ? "Preparing Print..." : "Print...") { store.perform(.printNote) }
                    .keyboardShortcut("p")
                    .disabled(FolioCommand.printNote.unavailableReason(in: store) != nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Across All Notes") {
                    openWindow(id: "library")
                    store.perform(.find)
                }
                .keyboardShortcut(store.shortcut(.find).keyboardShortcut)
                .disabled(!store.isLoaded)
            }
            CommandMenu("Navigate") {
                Button("Command Palette...") {
                    openWindow(id: "library")
                    store.showingCommands = true
                }.keyboardShortcut(store.shortcut(.palette).keyboardShortcut)
                Divider()
                Button("Back") { store.perform(.back) }
                    .keyboardShortcut(store.shortcut(.back).keyboardShortcut).disabled(!store.workspace.canGoBack)
                Button("Forward") { store.perform(.forward) }
                    .keyboardShortcut(store.shortcut(.forward).keyboardShortcut).disabled(!store.workspace.canGoForward)
                Button("Close Current Tab") { store.perform(.closeTab) }
                    .keyboardShortcut(store.shortcut(.closeTab).keyboardShortcut)
                    .disabled(store.selectedNote == nil)
                Divider()
                Button("Show Current Note as Reference") { store.perform(.reference) }
                    .disabled(store.selectedNote == nil)
                Button("Close Reference Pane") { store.perform(.closeReference) }
                    .disabled(store.referenceNote == nil)
                Divider()
                Button("Open Today's Note") { openWindow(id: "library"); store.perform(.today) }
                    .keyboardShortcut(store.shortcut(.today).keyboardShortcut)
                    .disabled(FolioCommand.today.unavailableReason(in: store) != nil)
                Button("Tasks...") { openWindow(id: "library"); store.perform(.tasks) }
                    .keyboardShortcut(store.shortcut(.tasks).keyboardShortcut)
                    .disabled(FolioCommand.tasks.unavailableReason(in: store) != nil)
                Divider()
                Button("Toggle Notebooks") { store.perform(.toggleFolders) }
                    .keyboardShortcut(store.shortcut(.toggleFolders).keyboardShortcut)
                Button("Toggle Note List") { store.perform(.toggleNotes) }
                    .keyboardShortcut(store.shortcut(.toggleNotes).keyboardShortcut)
            }
        }
        Window("Quick Capture", id: "capture") {
            QuickCaptureView().environmentObject(store)
        }
        .defaultSize(width: 480, height: 420)
        .windowResizability(.contentMinSize)
        Window("Live Markdown Library", id: "live-markdown") {
            LiveMarkdownView(model: markdown).environmentObject(store)
                .focusedSceneValue(\.liveMarkdown, markdown)
                .frame(minWidth: 820, minHeight: 580)
                .onAppear { delegate.markdown = markdown }
        }
        .defaultSize(width: 1240, height: 800)
        MenuBarExtra("Deltos", systemImage: "square.and.pencil") {
            Button("Quick Capture") { capture() }.disabled(!store.isLoaded)
            Button("Open Deltos") {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(store.isSyncing ? "Syncing..." : "Sync Now", action: store.syncNow)
                .disabled(store.syncFolderName == nil || store.isSyncing)
            Divider()
            Button("Quit Deltos") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        Settings { SettingsView().environmentObject(store) }
            .windowResizability(.contentMinSize)
    }

    private func capture() {
        openWindow(id: "capture")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: NotesStore?
    weak var markdown: LiveMarkdownStore?
    private let appearance = ApplicationAppearance()

    func applicationWillFinishLaunching(_ notification: Notification) {
        appearance.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.syncManager.stop()
        appearance.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard markdown?.confirmLeavingDraft() != false else { return .terminateCancel }
        if store?.backupManager?.busy == true {
            let alert = NSAlert()
            alert.messageText = "A complete backup is still running"
            alert.informativeText = "Wait for the backup to finish before quitting Deltos."
            alert.runModal()
            return .terminateCancel
        }
        guard let store, store.hasUnsavedChanges else { return .terminateNow }
        store.save()
        guard store.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your latest changes have not been saved"
        alert.informativeText = "Stay in Deltos to retry saving or export your notes. Quitting now will discard changes that could not be written to disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Deltos Open")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
