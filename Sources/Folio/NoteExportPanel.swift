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
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = String(MarkdownFile.filename(for: note).dropLast(3)) + "." + format.fileExtension
        formatPicker.addItems(withTitles: NoteExportFormat.allCases.map(\.rawValue))
        formatPicker.selectItem(withTitle: format.rawValue)
        formatPicker.target = self
        formatPicker.action = #selector(changeFormat)
        formatPicker.setAccessibilityLabel("File format")
        let label = NSTextField(labelWithString: "File format:")
        label.alignment = .right
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.widthAnchor.constraint(equalToConstant: 78).isActive = true
        formatPicker.font = .systemFont(ofSize: NSFont.systemFontSize)
        formatPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        formatPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        formatPicker.setContentCompressionResistancePriority(.required, for: .horizontal)
        let accessory = NSStackView(views: [label, formatPicker])
        accessory.orientation = .horizontal
        accessory.alignment = .firstBaseline
        accessory.distribution = .fill
        accessory.spacing = 12
        accessory.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        accessory.setFrameSize(NSSize(width: 350, height: 52))
        panel.accessoryView = accessory
        applyFormat()
    }

    @objc private func changeFormat() {
        format = NoteExportFormat.allCases[formatPicker.indexOfSelectedItem]
        applyFormat()
    }

    private func applyFormat() {
        panel.message = format == .pdf
            ? "PDF includes the rendered note and local images. Other attached files are not embedded."
            : "Attachments stay linked, not copied. To include them, use File > Export > Export Open Markdown Folder."
        let name = panel.nameFieldStringValue as NSString
        let suffixes = Set(NoteExportFormat.allCases.map(\.fileExtension))
        let stem = suffixes.contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : String(name)
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = stem + "." + format.fileExtension
    }
}
