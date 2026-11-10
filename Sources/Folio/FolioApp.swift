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
                Button("New Note") { openWindow(id: "library"); store.createNote() }
                    .keyboardShortcut("n")
                    .disabled(!store.isLoaded)
                Button("New Markdown Source Note") { openWindow(id: "library"); store.createMarkdownNote() }
                    .disabled(!store.isLoaded)
                Menu("New from Template") {
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
                    .keyboardShortcut(" ", modifiers: [.command, .shift])
                    .disabled(!store.isLoaded)
                Button("New Notebook") { store.notebookDraft = NotebookDraft() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.isLoaded)
                Divider()
                Button("Import Markdown or HTML Files...", action: store.importMarkdown)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!store.isLoaded)
                Button("Import Joplin Folder...", action: store.importJoplinFolder)
                    .disabled(!store.isLoaded || store.isImportingJoplin)
                Button("Import Markdown or HTML Folder...") { store.importJoplinFolder(includeHTML: true) }
                    .disabled(!store.isLoaded || store.isImportingJoplin)
                Button("Export Note...") {
                    if let note = store.selectedNote { store.exportMarkdown(note) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.selectedNote == nil)
                Divider()
                Button("Add Images or Attachments...", action: store.addAttachments)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(store.selectedNote == nil || store.selectedNote?.deletedAt != nil)
                Button("Export Complete Backup...", action: store.exportBackup)
                    .disabled(!store.isLoaded)
                Button("Export Open Markdown Folder...", action: store.exportVault)
                    .disabled(!store.isLoaded)
                Button("Import Folio Backup...", action: store.importBackup)
                    .disabled(!store.isLoaded)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save", action: store.save)
                    .keyboardShortcut("s")
                    .disabled(!store.isLoaded)
                Button("Show Library in Finder", action: store.revealLibrary)
                Divider()
                Button("Connect iCloud Drive Folder...", action: store.chooseSyncFolder)
                    .disabled(!store.isLoaded || store.isSyncing)
                Button("Sync Now", action: store.syncNow)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(store.syncFolderName == nil || store.isSyncing)
                Button("Disconnect Shared Folder", action: store.disconnectSyncFolder)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Across All Notes") {
                    openWindow(id: "library")
                    store.showingFinder = true
                }
                .keyboardShortcut("k")
                .disabled(!store.isLoaded)
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
        Settings { AppearanceSettings() }
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
