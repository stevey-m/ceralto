import AppKit
import NotesCore
import UniformTypeIdentifiers

@MainActor
final class NoteExportPanel: NSObject {
    let panel = NSSavePanel()
    let formatPicker = NSPopUpButton()
    private(set) var format: NoteExportFormat

    init(note: Note) {
        format = note.contentFormat == .html ? .html : .markdown
        super.init()
        panel.title = "Export Note"
        panel.prompt = "Export"
        panel.message = "Choose a file format. Attachments are linked, not copied. Use File > Export Open Markdown Folder to include attachments. For PDF, use File > Print > PDF > Save as PDF."
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = String(MarkdownFile.filename(for: note).dropLast(3)) + "." + format.fileExtension
        formatPicker.addItems(withTitles: NoteExportFormat.allCases.map(\.rawValue))
        formatPicker.selectItem(withTitle: format.rawValue)
        formatPicker.target = self
        formatPicker.action = #selector(changeFormat)
        formatPicker.setAccessibilityLabel("File format")
        let label = NSTextField(labelWithString: "File format:")
        let accessory = NSStackView(views: [label, formatPicker])
        accessory.orientation = .horizontal
        accessory.spacing = 12
        accessory.setFrameSize(NSSize(width: 350, height: 32))
        panel.accessoryView = accessory
        applyFormat()
    }

    @objc private func changeFormat() {
        format = NoteExportFormat.allCases[formatPicker.indexOfSelectedItem]
        applyFormat()
    }

    private func applyFormat() {
        let name = panel.nameFieldStringValue as NSString
        let suffixes = Set(NoteExportFormat.allCases.map(\.fileExtension))
        let stem = suffixes.contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : String(name)
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = stem + "." + format.fileExtension
    }
}
