import AppKit
import SwiftUI

@main
struct FolioApp: App {
    @StateObject private var store = NotesStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Folio", id: "library") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { delegate.store = store }
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
                    if store.extensions.isEmpty { Text("No template extensions installed") }
                    ForEach(store.extensions) { pack in
                        Menu(pack.name) {
                            ForEach(pack.templates) { template in
                                Button(template.name) { store.createFromTemplate(template) }
                            }
                        }
                    }
                    Divider()
                    Button("Open Extensions Folder", action: store.revealExtensions)
                    Button("Reload Extensions", action: store.reloadExtensions)
                }.disabled(!store.isLoaded)
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
                Button("Import Joplin Folder...", action: store.importJoplinFolder)
                    .disabled(!store.isLoaded || store.isImportingJoplin)
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
                    .disabled(!store.isLoaded)
                Button("Export Open Markdown Folder...", action: store.exportVault)
                    .disabled(!store.isLoaded)
                Button("Import Folio Backup...", action: store.importBackup)
                    .disabled(!store.isLoaded)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.perform(.save) }
                    .keyboardShortcut(store.shortcut(.save).keyboardShortcut)
                    .disabled(!store.isLoaded)
                Button("Show Library in Finder", action: store.revealLibrary)
                Button("Show Local Recovery Copies...", action: store.revealRecoveryCopies)
                Divider()
                Button("Connect iCloud Drive Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing)
                Button("Sync Now", action: store.syncNow)
                    .keyboardShortcut(store.shortcut(.sync).keyboardShortcut)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
                Button("Disconnect Shared Folder", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
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
                    .keyboardShortcut(store.shortcut(.today).keyboardShortcut).disabled(!store.isLoaded)
                Button("Tasks...") { openWindow(id: "library"); store.perform(.tasks) }
                    .keyboardShortcut(store.shortcut(.tasks).keyboardShortcut).disabled(!store.isLoaded)
                Divider()
                Button("Toggle Main Folders") { store.perform(.toggleFolders) }
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
        MenuBarExtra("Folio", systemImage: "square.and.pencil") {
            Button("Quick Capture") { capture() }.disabled(!store.isLoaded)
            Button("Open Folio") {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(store.isSyncing ? "Syncing..." : "Sync Now", action: store.syncNow)
                .disabled(store.syncFolderName == nil || store.isSyncing)
            Divider()
            Button("Quit Folio") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        Settings { SettingsView().environmentObject(store) }
    }

    private func capture() {
        openWindow(id: "capture")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: NotesStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedChanges else { return .terminateNow }
        store.save()
        guard store.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your latest changes have not been saved"
        alert.informativeText = "Stay in Folio to retry saving or export your notes. Quitting now will discard changes that could not be written to disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Folio Open")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
