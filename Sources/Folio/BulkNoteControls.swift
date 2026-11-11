import AppKit
import NotesCore

extension NotesStore {
    func runBulkAction(_ action: BulkNoteAction, ids: Set<UUID>) {
        do { try applyBulkAction(action, to: ids) }
        catch { errorMessage = "Could not update selected notes: \(error.localizedDescription)" }
    }

    func confirmBulkTrash(_ ids: Set<UUID>) {
        let alert = NSAlert()
        alert.messageText = "Move \(ids.count) notes to Trash?"
        alert.informativeText = "The selected notes will remain recoverable in Trash. Nothing is permanently deleted."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runBulkAction(.trash, ids: ids)
    }

    func addTagsToNotes(_ ids: Set<UUID>) {
        let alert = NSAlert()
        alert.messageText = "Add tags to \(ids.count) notes"
        alert.informativeText = "Enter comma-separated tags. Existing tags are preserved."
        alert.addButton(withTitle: "Add Tags")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "work, ideas"
        field.setAccessibilityLabel("Tags for selected notes")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runBulkAction(.addTags(field.stringValue.components(separatedBy: ",")), ids: ids)
    }

    func exportSelectedNotes(_ ids: Set<UUID>) {
        let panel = NSOpenPanel()
        panel.title = "Export \(ids.count) Selected Notes"
        panel.message = "Creates a new portable Markdown/HTML folder with metadata and linked attachments. This is not a complete history backup. Links to unselected notes are not exported."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let accessing = parent.startAccessingSecurityScopedResource()
        defer { if accessing { parent.stopAccessingSecurityScopedResource() } }
        let folder = parent.appendingPathComponent("Ceralto Selected Notes " + UUID().uuidString, isDirectory: true)
        do {
            try exportSelectedNotes(ids, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { errorMessage = "Selected-note export failed: \(error.localizedDescription)" }
    }
}
