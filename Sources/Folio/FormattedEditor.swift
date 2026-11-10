import AppKit
import NotesCore
import SwiftUI

extension NSAttributedString.Key {
    static let folioBlock = Self("FolioBlock")
    static let folioMarker = Self("FolioMarker")
    static let folioImage = Self("FolioImage")
    static let folioAlt = Self("FolioAlt")
    static let folioCode = Self("FolioCode")
    static let folioBold = Self("FolioBold")
}

@MainActor
enum NativePageCodec {
    static func font(_ family: ReadingFont, size: Double) -> NSFont {
        switch family {
        case .system: .systemFont(ofSize: size)
        case .monospace: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif: NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        }
    }

    static func attributes(style: FormattedBlock.Style, size: Double, family: ReadingFont,
                           color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        if style == .bullet || style == .quote { paragraph.headIndent = 22 }
        let scale = style == .heading1 ? 1.8 : style == .heading2 ? 1.35 : 1
        var face = font(style == .code ? .monospace : family, size: size * scale)
        if style == .heading1 || style == .heading2 {
            face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)
        }
        return [.font: face, .foregroundColor: color, .paragraphStyle: paragraph,
                .folioBlock: style.rawValue, .folioBold: false]
    }

    static func decode(_ html: String, resources: ImportedResources?, size: Double = 16,
                       family: ReadingFont = .system, color: NSColor = .textColor) throws -> NSAttributedString {
        let page = try FormattedPage(html: html)
        let result = NSMutableAttributedString(string: "")
        for (index, block) in page.blocks.enumerated() {
            let base = attributes(style: block.style, size: size, family: family, color: color)
            if block.style == .bullet {
                var marker = base
                marker[.folioMarker] = true
                result.append(NSAttributedString(string: "\u{2022} ", attributes: marker))
            }
            for run in block.runs {
                var attrs = base
                if let image = run.image {
                    let attachment = NSTextAttachment()
                    let local = resources?.localURL(for: image)
                    let picture = local.flatMap { url -> NSImage? in
                        guard ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"]
                            .contains(url.pathExtension.lowercased()) else { return nil }
                        return NSImage(contentsOf: url)
                    }
                    attachment.image = picture ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Image unavailable")
                    let original = picture?.size ?? NSSize(width: 120, height: 80)
                    let width = min(max(original.width, 1), 640)
                    attachment.bounds = NSRect(x: 0, y: 0, width: width,
                                               height: width * max(original.height, 1) / max(original.width, 1))
                    attrs[.attachment] = attachment
                    attrs[.folioImage] = image
                    attrs[.folioAlt] = run.text
                    result.append(NSAttributedString(string: "\u{fffc}", attributes: attrs))
                    continue
                }
                var face = attrs[.font] as? NSFont ?? font(family, size: size)
                if run.code { face = font(.monospace, size: face.pointSize) }
                if run.bold { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
                if run.italic { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
                attrs[.font] = face
                attrs[.folioBold] = run.bold
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if run.code {
                    attrs[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
                    attrs[.folioCode] = true
                }
                if let link = run.link { attrs[.link] = link }
                result.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if index < page.blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
    }

    static func encode(_ text: NSAttributedString, markdown: Bool = false) -> String {
        let string = text.string as NSString
        var blocks: [FormattedBlock] = []
        var start = 0
        while start < text.length {
            let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
            var length = paragraph.length
            while length > 0 && ["\n", "\r"].contains(string.substring(with: NSRange(location: start + length - 1, length: 1))) {
                length -= 1
            }
            let kind = text.attribute(.folioBlock, at: start, effectiveRange: nil) as? String
            let style = FormattedBlock.Style(rawValue: kind ?? "") ?? .paragraph
            var runs: [FormattedRun] = []
            text.enumerateAttributes(in: NSRange(location: start, length: length)) { attrs, range, _ in
                if attrs[.folioMarker] as? Bool == true { return }
                var run = FormattedRun(text: string.substring(with: range))
                if let image = attrs[.folioImage] as? String {
                    run.image = image
                    run.text = attrs[.folioAlt] as? String ?? ""
                } else {
                    if let face = attrs[.font] as? NSFont {
                        let traits = NSFontManager.shared.traits(of: face)
                        run.bold = attrs[.folioBold] as? Bool ?? traits.contains(.boldFontMask)
                        run.italic = traits.contains(.italicFontMask)
                    }
                    run.code = attrs[.folioCode] as? Bool == true
                    run.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
                    run.struck = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
                    if let url = attrs[.link] as? URL { run.link = url.absoluteString }
                    else { run.link = attrs[.link] as? String }
                }
                runs.append(run)
            }
            blocks.append(FormattedBlock(style: style, runs: runs))
            start = paragraph.location + paragraph.length
        }
        if text.length > 0 && text.string.hasSuffix("\n") { blocks.append(FormattedBlock(runs: [])) }
        let page = FormattedPage(blocks: blocks)
        return markdown ? page.markdown() : page.html()
    }
}

@MainActor
final class FormattingActions: ObservableObject {
    weak var editor: PageTextView?
    @Published var style = FormattedBlock.Style.paragraph
    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var struck = false
    @Published var code = false
    @Published var linked = false

    func refresh() {
        guard let editor else { return }
        let selection = editor.selectedRange()
        var attributes: [[NSAttributedString.Key: Any]] = []
        if selection.length > 0 {
            editor.textStorage?.enumerateAttributes(in: selection) { attrs, _, _ in
                if attrs[.folioMarker] as? Bool != true { attributes.append(attrs) }
            }
        }
        if attributes.isEmpty { attributes = [editor.typingAttributes] }
        style = FormattedBlock.Style(rawValue: attributes[0][.folioBlock] as? String ?? "") ?? .paragraph
        bold = attributes.allSatisfy { $0[.folioBold] as? Bool == true }
        italic = attributes.allSatisfy {
            NSFontManager.shared.traits(of: $0[.font] as? NSFont ?? .systemFont(ofSize: 16)).contains(.italicFontMask)
        }
        underline = attributes.allSatisfy { ($0[.underlineStyle] as? Int ?? 0) != 0 }
        struck = attributes.allSatisfy { ($0[.strikethroughStyle] as? Int ?? 0) != 0 }
        code = attributes.allSatisfy { $0[.folioCode] as? Bool == true }
        linked = attributes.contains { $0[.link] != nil }
    }

    func toggle(_ trait: NSFontTraitMask) {
        guard let editor, editor.isEditable else { return }
        refresh()
        let range = editor.selectedRange()
        let removing = trait == .boldFontMask ? bold : italic
        func formatted(_ current: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attrs = current
            let face = current[.font] as? NSFont ?? .systemFont(ofSize: 16)
            let heading = [FormattedBlock.Style.heading1.rawValue, FormattedBlock.Style.heading2.rawValue]
                .contains(current[.folioBlock] as? String ?? "")
            attrs[.font] = removing && !(trait == .boldFontMask && heading)
                ? NSFontManager.shared.convert(face, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(face, toHaveTrait: trait)
            if trait == .boldFontMask { attrs[.folioBold] = !removing }
            attrs.removeValue(forKey: .folioMarker)
            return attrs
        }
        if range.length == 0 {
            editor.typingAttributes = formatted(editor.typingAttributes)
        } else {
            editor.editAttributes(name: "Format Text") { storage in
                storage.enumerateAttributes(in: range) { attrs, subrange, _ in
                    guard attrs[.folioMarker] as? Bool != true else { return }
                    storage.setAttributes(formatted(attrs), range: subrange)
                }
            }
        }
        refresh()
        editor.window?.makeFirstResponder(editor)
    }

    func setStyle(_ style: FormattedBlock.Style) {
        guard let editor, editor.isEditable, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        let range = (storage.string as NSString).paragraphRange(for: selection)
        let attrs = NativePageCodec.attributes(style: style, size: editor.pageFontSize,
                                               family: editor.pageFont, color: editor.textColor ?? .textColor)
        if range.length == 0 {
            editor.typingAttributes = attrs
            if style == .bullet {
                var marker = attrs
                marker[.folioMarker] = true
                editor.insertText(NSAttributedString(string: "\u{2022} ", attributes: marker), replacementRange: selection)
                editor.typingAttributes = attrs
            }
        } else {
            var paragraphs: [NSRange] = []
            var start = range.location
            while start < range.upperBound {
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
                paragraphs.append(paragraph)
                start = paragraph.upperBound
            }
            var anchor = selection.location
            var end = selection.upperBound
            editor.editAttributes(name: "Paragraph Style") { text in
                for paragraph in paragraphs.reversed() {
                    var markerRange = NSRange(location: paragraph.location, length: 0)
                    if text.attribute(.folioMarker, at: paragraph.location, effectiveRange: &markerRange) as? Bool != true {
                        markerRange.length = 0
                    }
                    markerRange = NSIntersectionRange(markerRange, paragraph)
                    let removed = markerRange.length
                    if removed > 0 { text.deleteCharacters(in: markerRange) }
                    let body = NSRange(location: paragraph.location, length: paragraph.length - removed)
                    text.enumerateAttributes(in: body) { original, subrange, _ in
                        var updated = original
                        updated[.folioBlock] = attrs[.folioBlock]
                        updated[.paragraphStyle] = attrs[.paragraphStyle]
                        updated[.font] = Self.face(for: updated, editor: editor)
                        text.setAttributes(updated, range: subrange)
                    }
                    let inserted = style == .bullet ? 2 : 0
                    if inserted > 0 {
                        var marker = attrs
                        marker[.folioMarker] = true
                        text.insert(NSAttributedString(string: "\u{2022} ", attributes: marker), at: paragraph.location)
                    }
                    func shifted(_ offset: Int) -> Int {
                        guard offset >= paragraph.location else { return offset }
                        return offset >= paragraph.location + removed
                            ? offset + inserted - removed : paragraph.location + inserted
                    }
                    anchor = shifted(anchor)
                    end = shifted(end)
                }
            }
            editor.setSelectedRange(NSRange(location: anchor, length: max(0, end - anchor)))
            var typing = editor.typingAttributes
            typing[.folioBlock] = style.rawValue
            typing[.paragraphStyle] = attrs[.paragraphStyle]
            typing[.font] = Self.face(for: typing, editor: editor)
            typing.removeValue(forKey: .folioMarker)
            editor.typingAttributes = typing
        }
        self.style = style
        refresh()
        editor.window?.makeFirstResponder(editor)
    }

    private static func face(for attrs: [NSAttributedString.Key: Any], editor: PageTextView) -> NSFont {
        let style = FormattedBlock.Style(rawValue: attrs[.folioBlock] as? String ?? "") ?? .paragraph
        var face = NativePageCodec.attributes(style: style, size: editor.pageFontSize,
            family: attrs[.folioCode] as? Bool == true ? .monospace : editor.pageFont,
            color: editor.textColor ?? .textColor)[.font] as? NSFont ?? .systemFont(ofSize: editor.pageFontSize)
        if attrs[.folioBold] as? Bool == true {
            face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)
        }
        if let original = attrs[.font] as? NSFont,
           NSFontManager.shared.traits(of: original).contains(.italicFontMask) {
            face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask)
        }
        return face
    }

    func toggleInline(_ key: NSAttributedString.Key) {
        guard let editor, editor.isEditable else { return }
        refresh()
        let enabled = key == .folioCode ? code : key == .underlineStyle ? underline : struck
        func formatted(_ original: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attrs = original
            if key == .folioCode {
                attrs[.folioCode] = !enabled
                if enabled { attrs.removeValue(forKey: .backgroundColor) }
                else { attrs[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.1) }
                attrs[.font] = Self.face(for: attrs, editor: editor)
            } else {
                attrs[key] = enabled ? 0 : NSUnderlineStyle.single.rawValue
            }
            return attrs
        }
        let range = editor.selectedRange()
        if range.length == 0 { editor.typingAttributes = formatted(editor.typingAttributes) }
        else {
            editor.editAttributes(name: "Format Text") { storage in
                storage.enumerateAttributes(in: range) { attrs, subrange, _ in
                    guard attrs[.folioMarker] as? Bool != true else { return }
                    storage.setAttributes(formatted(attrs), range: subrange)
                }
            }
        }
        refresh()
        editor.window?.makeFirstResponder(editor)
    }

    func removeLink() {
        guard let editor, editor.isEditable else { return }
        var range = editor.selectedRange()
        if range.length == 0, let storage = editor.textStorage, storage.length > 0 {
            let index = min(range.location, storage.length - 1)
            guard storage.attribute(.link, at: index, effectiveRange: &range) != nil else { return }
        }
        editor.editAttributes(name: "Remove Link") { $0.removeAttribute(.link, range: range) }
        var typing = editor.typingAttributes
        typing.removeValue(forKey: .link)
        editor.typingAttributes = typing
        refresh()
        editor.window?.makeFirstResponder(editor)
    }

    func chooseAttachments() {
        guard let editor, editor.isEditable else { return }
        let panel = NSOpenPanel()
        panel.title = "Insert Images or Attachments"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        editor.insertFiles(panel.urls)
    }

    @discardableResult
    func addLink(_ value: String) -> Bool {
        guard let editor, editor.isEditable else { return false }
        guard FormattedPage.allowedLink(value), let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              !value.contains(where: \.isWhitespace),
              scheme == "mailto" ? !components.path.isEmpty : !(components.host ?? "").isEmpty else {
            editor.onError?("Enter a complete http, https, or mailto link.")
            return false
        }
        let range = editor.selectedRange()
        if range.length == 0 {
            var attrs = editor.typingAttributes
            attrs[.link] = value
            editor.insertText(NSAttributedString(string: value, attributes: attrs), replacementRange: range)
        } else {
            editor.editAttributes(name: "Add Link") { $0.addAttribute(.link, value: value, range: range) }
        }
        refresh()
        editor.window?.makeFirstResponder(editor)
        return true
    }
}

@MainActor
class DocumentTextView: NSTextView {
    private lazy var documentUndo: UndoManager = {
        let manager = UndoManager()
        NotificationCenter.default.addObserver(self, selector: #selector(publishUndo),
            name: .NSUndoManagerDidUndoChange, object: manager)
        NotificationCenter.default.addObserver(self, selector: #selector(publishUndo),
            name: .NSUndoManagerDidRedoChange, object: manager)
        return manager
    }()
    override var undoManager: UndoManager? { documentUndo }

    @objc private func publishUndo(_ notification: Notification) {
        // NSTextView's private undo operations do not always notify our persistence delegate.
        didChangeText()
    }
}

@MainActor
final class PageTextView: DocumentTextView {
    var resources: ImportedResources?
    var onImportFiles: (([URL]) throws -> Attachments.Imported)?
    var onError: ((String) -> Void)?
    var onImage: ((URL) -> Void)?
    var pageFontSize = 16.0
    var pageFont = ReadingFont.system

    override func mouseDown(with event: NSEvent) {
        if openImage(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    @discardableResult
    func openImage(at point: NSPoint) -> Bool {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return false }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: location, in: container)
        guard glyph < layout.numberOfGlyphs else { return false }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let reference = storage.attribute(.folioImage, at: index, effectiveRange: nil) as? String,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location)
        else { return false }
        guard let url = resources?.localURL(for: reference), let onImage else {
            onError?("This image is missing or its viewer is unavailable.")
            return true
        }
        onImage(url)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let style = FormattedBlock.Style(rawValue: typingAttributes[.folioBlock] as? String ?? "") ?? .paragraph
        if style == .bullet, let storage = textStorage, storage.length > 0 {
            let range = (storage.string as NSString).paragraphRange(for: selectedRange())
            let paragraph = storage.attributedSubstring(from: range)
            let visible = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if visible == "\u{2022}" {
                insertText("", replacementRange: range)
                typingAttributes = NativePageCodec.attributes(style: .paragraph, size: pageFontSize,
                    family: pageFont, color: textColor ?? .textColor)
                return
            }
        }
        super.insertNewline(sender)
        if style == .bullet {
            var attrs = NativePageCodec.attributes(style: .bullet, size: pageFontSize,
                                                   family: pageFont, color: textColor ?? .textColor)
            attrs[.folioMarker] = true
            insertText(NSAttributedString(string: "\u{2022} ", attributes: attrs), replacementRange: selectedRange())
            attrs.removeValue(forKey: .folioMarker)
            typingAttributes = attrs
        } else if style == .heading1 || style == .heading2 {
            typingAttributes = NativePageCodec.attributes(style: .paragraph, size: pageFontSize,
                family: pageFont, color: textColor ?? .textColor)
        }
    }

    override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pastePlain(from: .general)
    }

    func pastePlain(from board: NSPasteboard) {
        guard isEditable else { return }
        guard let value = board.string(forType: .string) else {
            onError?("The clipboard has no plain-text representation.")
            return
        }
        insertText(value, replacementRange: selectedRange())
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func copy(_ sender: Any?) { copy(to: .general) }

    override func cut(_ sender: Any?) {
        cut(to: .general)
    }

    func cut(to board: NSPasteboard) {
        guard isEditable, copy(to: board) else { return }
        insertText("", replacementRange: selectedRange())
    }

    @discardableResult
    func copy(to board: NSPasteboard) -> Bool {
        guard selectedRange().length > 0 else { return false }
        do {
            try RichClipboard.write(attributedString().attributedSubstring(from: selectedRange()), resources: resources, to: board)
            return true
        } catch {
            onError?("Could not copy formatted content: \(error.localizedDescription)")
            return false
        }
    }

    func paste(from board: NSPasteboard) {
        guard isEditable else { return }
        do {
            if let content = try RichClipboard.read(board) {
                try insertRich(content)
                return
            }
        } catch {
            onError?("Could not paste formatted content; your note was not changed. \(error.localizedDescription)")
            return
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            insertFiles(urls)
        } else if board.availableType(from: [.png, .tiff]) != nil {
            do {
                let bytes: Data
                if let png = board.data(forType: .png), NSBitmapImageRep(data: png) != nil {
                    bytes = png
                } else if let tiff = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) {
                    bytes = png
                } else {
                    throw JoplinImportError.invalid("The clipboard image could not be decoded. Copy it again or attach the original file.")
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Deltos-paste-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer {
                    do { try FileManager.default.removeItem(at: folder) }
                    catch { onError?("The image paste temporary file could not be removed: \(error.localizedDescription)") }
                }
                let image = folder.appendingPathComponent("Pasted image.png")
                try bytes.write(to: image, options: .atomic)
                insertFiles([image])
            } catch {
                onError?("Could not paste this image: \(error.localizedDescription)")
            }
        } else if let text = board.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        } else {
            onError?("The clipboard does not contain text, a supported image or files.")
        }
    }

    func insertRich(_ content: RichClipboard.Content) throws {
        guard isEditable else { throw NoteWorkflowError("This editor is read-only.") }
        var page = content.page
        var newResources = resources
        if !content.images.isEmpty {
            guard let onImportFiles else { throw NoteWorkflowError("Image attachment insertion is unavailable.") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Deltos-rich-paste-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer {
                do { try FileManager.default.removeItem(at: folder) }
                catch { onError?("Could not remove clipboard temporary files: \(error.localizedDescription)") }
            }
            var files: [URL] = []
            for image in content.images {
                let file = folder.appendingPathComponent(image.name)
                try image.data.write(to: file)
                files.append(file)
            }
            let imported = try onImportFiles(files)
            let references = try FormattedPage(markdown: imported.fragment).blocks.flatMap(\.runs).compactMap(\.image)
            guard references.count == content.images.count else { throw NoteWorkflowError("Clipboard images could not be mapped to managed attachments.") }
            let mapping = Dictionary(uniqueKeysWithValues: zip(content.images.map(\.name), references))
            for block in page.blocks.indices {
                for run in page.blocks[block].runs.indices {
                    if let image = page.blocks[block].runs[run].image {
                        guard let local = mapping[image] else { throw NoteWorkflowError("A clipboard image has no managed attachment.") }
                        page.blocks[block].runs[run].image = local
                    }
                }
            }
            newResources = imported.resources
        }
        let value = try NativePageCodec.decode(page.html(), resources: newResources, size: pageFontSize,
                                              family: pageFont, color: textColor ?? .textColor)
        resources = newResources
        window?.makeFirstResponder(self)
        let selection = selectedRange()
        // NSTextView.insertText normalizes pasted font sizes to the insertion paragraph.
        editAttributes(name: "Paste Formatted Content") {
            $0.replaceCharacters(in: selection, with: value)
        }
        setSelectedRange(NSRange(location: selection.location + value.length, length: 0))
        var typing = value.length > 0 ? value.attributes(at: value.length - 1, effectiveRange: nil) : typingAttributes
        for key in [NSAttributedString.Key.folioMarker, .folioImage, .folioAlt, .attachment] {
            typing.removeValue(forKey: key)
        }
        typingAttributes = typing
        setFrameSize(frame.size)
    }

    @discardableResult
    func insertFiles(_ urls: [URL]) -> Bool {
        guard isEditable else { return false }
        guard let onImportFiles else {
            onError?("Attachment insertion is unavailable.")
            return false
        }
        do {
            let imported = try onImportFiles(urls)
            let page = try FormattedPage(markdown: imported.fragment)
            let inserted = try NativePageCodec.decode(page.html(), resources: imported.resources, size: pageFontSize,
                family: pageFont, color: textColor ?? .textColor)
            resources = imported.resources
            let addition = NSMutableAttributedString(attributedString: inserted)
            let range = selectedRange()
            let body = string as NSString
            let attrs = NativePageCodec.attributes(style: .paragraph, size: pageFontSize,
                family: pageFont, color: textColor ?? .textColor)
            if range.location > 0 && body.substring(with: NSRange(location: range.location - 1, length: 1)) != "\n" {
                addition.insert(NSAttributedString(string: "\n", attributes: attrs), at: 0)
            }
            if range.upperBound < body.length && body.substring(with: NSRange(location: range.upperBound, length: 1)) != "\n" {
                addition.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            window?.makeFirstResponder(self)
            insertText(addition, replacementRange: range)
            undoManager?.setActionName("Insert Attachment")
            typingAttributes = attrs
            setFrameSize(frame.size)
            return true
        } catch {
            onError?("Could not insert attachments: \(error.localizedDescription)")
            return false
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let previous = selectedRange()
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            let inserted = insertFiles(urls)
            if !inserted { setSelectedRange(previous) }
            return inserted
        }
        return super.performDragOperation(sender)
    }

    func editAttributes(name: String, _ edit: (NSMutableAttributedString) -> Void) {
        guard let storage = textStorage else { return }
        let previous = NSAttributedString(attributedString: storage)
        let selection = selectedRange()
        let restore: @MainActor (PageTextView) -> Void = { target in
            target.restore(previous, selection: selection, name: name)
        }
        undoManager?.registerUndo(withTarget: self) { target in
            // This text view's undo manager is invoked synchronously on the main thread.
            MainActor.assumeIsolated { restore(target) }
        }
        undoManager?.setActionName(name)
        storage.beginEditing()
        edit(storage)
        storage.endEditing()
        let safeSelection = NSRange(location: min(selection.location, storage.length),
                                    length: min(selection.length, max(0, storage.length - selection.location)))
        setSelectedRange(safeSelection)
        didChangeText()
    }

    private func restore(_ value: NSAttributedString, selection: NSRange, name: String) {
        editAttributes(name: name) { $0.setAttributedString(value) }
        setSelectedRange(selection)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let storage = textStorage else { return }
        let width = max(100, newSize.width - textContainerInset.width * 2 - 12)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
            let natural = image.size
            let fitted = width
            attachment.bounds = NSRect(x: 0, y: 0, width: fitted,
                                      height: fitted * max(1, natural.height) / max(1, natural.width))
        }
    }
}

struct FormattedEditor: View {
    let note: Note
    let fontSize: Double
    let family: ReadingFont
    let dracula: Bool
    @ObservedObject var actions: FormattingActions
    var onChange: (String) -> Void
    var onError: (String) -> Void
    var onImage: (URL) -> Void
    var currentSource: (() -> String)?
    var onImportFiles: (([URL]) throws -> Attachments.Imported)?
    @ViewState private var addingLink = false
    @ViewState private var link = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Menu {
                    ForEach(FormattedBlock.Style.allCases, id: \.rawValue) { style in
                        Button(style.title) { actions.setStyle(style) }
                    }
                } label: { Text(actions.style.title).frame(minWidth: 56, alignment: .leading) }
                .menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 18)
                Button { actions.toggle(.boldFontMask) } label: { Image(systemName: "bold") }
                    .keyboardShortcut("b").help("Bold (Command-B)").accessibilityLabel("Bold")
                    .background(actions.bold ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityValue(actions.bold ? "On" : "Off")
                Button { actions.toggle(.italicFontMask) } label: { Image(systemName: "italic") }
                    .keyboardShortcut("i").help("Italic (Command-I)").accessibilityLabel("Italic")
                    .background(actions.italic ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityValue(actions.italic ? "On" : "Off")
                Menu {
                    Button(actions.underline ? "Remove Underline" : "Underline") { actions.toggleInline(.underlineStyle) }
                        .keyboardShortcut("u")
                    Button(actions.struck ? "Remove Strikethrough" : "Strikethrough") { actions.toggleInline(.strikethroughStyle) }
                    Button(actions.code ? "Remove Inline Code" : "Inline Code") { actions.toggleInline(.folioCode) }
                    Divider()
                    Button("Remove Link") { actions.removeLink() }.disabled(!actions.linked)
                } label: { Image(systemName: "textformat") }
                .help("More text formatting").accessibilityLabel("More text formatting")
                Button { actions.setStyle(actions.style == .bullet ? .paragraph : .bullet) } label: { Image(systemName: "list.bullet") }
                    .help("Bullet list").accessibilityLabel("Bullet list")
                    .background(actions.style == .bullet ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityValue(actions.style == .bullet ? "On" : "Off")
                Button { addingLink = true } label: { Image(systemName: "link") }
                    .help("Add link").accessibilityLabel("Add link")
                Spacer()
                Text("COMPOSE").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 28).padding(.vertical, 12)
            Divider()
            NativePageView(html: note.body, resources: resources, size: fontSize, family: family,
                           dracula: dracula, actions: actions, onChange: onChange,
                           onError: onError, onImage: onImage, currentSource: currentSource, onImportFiles: onImportFiles)
        }
        .popover(isPresented: $addingLink) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link to a page").font(.headline)
                TextField("https://", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(insertLink)
                Button("Insert Link", action: insertLink).keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 320)
        }
    }

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

    private func insertLink() {
        guard actions.addLink(link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        addingLink = false
        link = ""
    }
}

private final class PageScrollView: NSScrollView {
    override func tile() {
        super.tile()
        fitPage()
    }

    override func layout() {
        super.layout()
        fitPage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitPage()
    }

    private func fitPage() {
        guard let editor = documentView as? PageTextView else { return }
        let target = NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height))
        if abs(editor.frame.width - target.width) > 0.5 || editor.frame.height < target.height {
            editor.setFrameSize(target)
        }
    }
}

struct NativePageView: NSViewRepresentable {
    @AppStorage("composeSpellChecking") private var spellChecking = true
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @AppStorage("folioDraculaAccent") private var draculaAccent = "Theme default"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let html: String
    let resources: ImportedResources?
    let size: Double
    let family: ReadingFont
    let dracula: Bool
    let actions: FormattingActions
    var onChange: (String) -> Void
    var onError: (String) -> Void
    var onImage: ((URL) -> Void)?
    var currentSource: (() -> String)?
    var onImportFiles: (([URL]) throws -> Attachments.Imported)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PageScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = PageTextView(frame: .zero)
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 28, height: 28)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.registerForDraggedTypes([.fileURL])
        editor.setAccessibilityLabel("Formatted note editor")
        scroll.documentView = editor
        actions.editor = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PageTextView else { return }
        // A queued split-view update can still contain the note's pre-edit snapshot.
        let html = currentSource?() ?? self.html
        let coordinator = context.coordinator
        coordinator.parent = self
        let previousResources = editor.resources
        editor.resources = resources
        editor.onImportFiles = onImportFiles
        editor.onError = onError
        editor.onImage = onImage
        editor.isContinuousSpellCheckingEnabled = spellChecking
        editor.isEditable = isEnabled && coordinator.loadedHTML == html
        editor.isSelectable = isEnabled
        if !isEnabled, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
        editor.pageFont = family
        editor.pageFontSize = size
        let color = dracula ? NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1) : .textColor
        editor.textColor = color
        editor.insertionPointColor = color
        FolioPalette.style(editor, dracula: dracula)
        let linkColor = FolioPalette.accent(dracula ? .dracula : .system, accent: accent,
                                           draculaAccent: draculaAccent, scheme: colorScheme)
        editor.linkTextAttributes = [
            .foregroundColor: NSColor(linkColor),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        // Resource ownership can change during an insertion without replacing the native buffer or its undo history.
        if coordinator.loadedHTML == html && coordinator.size == size &&
            coordinator.family == family && coordinator.dracula == dracula && previousResources == resources {
            coordinator.resources = resources
            FolioPalette.styleRichText(editor, dracula: dracula, accent: linkColor)
            return
        }
        do {
            let selection = editor.selectedRange()
            let page = try FormattedPage(markdown: html)
            let decoded = try NativePageCodec.decode(page.html(), resources: resources, size: size, family: family, color: color)
            coordinator.updating = true
            defer { coordinator.updating = false }
            editor.textStorage?.setAttributedString(decoded)
            FolioPalette.styleRichText(editor, dracula: dracula, accent: linkColor)
            let location = min(selection.location, decoded.length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, decoded.length - location)))
            var typing = decoded.length > 0
                ? decoded.attributes(at: min(location, decoded.length - 1), effectiveRange: nil)
                : NativePageCodec.attributes(style: .paragraph, size: size, family: family, color: color)
            for key in [NSAttributedString.Key.folioMarker, .folioImage, .folioAlt, .attachment] {
                typing.removeValue(forKey: key)
            }
            editor.typingAttributes = typing
            editor.isEditable = isEnabled
            if coordinator.loadedHTML != nil && coordinator.loadedHTML != html { editor.undoManager?.removeAllActions() }
            coordinator.loadedHTML = html
            coordinator.size = size
            coordinator.family = family
            coordinator.dracula = dracula
            coordinator.resources = resources
            editor.setFrameSize(editor.frame.size)
            Task { @MainActor [weak editor] in
                guard let editor, actions.editor === editor else { return }
                actions.refresh()
            }
        } catch {
            editor.isEditable = false
            onError("Could not open the formatted editor. Your saved note has not been changed: \(error.localizedDescription)")
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePageView
        var loadedHTML: String?
        var resources: ImportedResources?
        var size = 0.0
        var family = ReadingFont.system
        var dracula = false
        var updating = false

        init(parent: NativePageView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? PageTextView,
                  let storage = editor.textStorage else { return }
            loadedHTML = NativePageCodec.encode(storage, markdown: true)
            if let loadedHTML { parent.onChange(loadedHTML) }
            var typing = editor.typingAttributes
            typing.removeValue(forKey: .folioMarker)
            typing.removeValue(forKey: .folioImage)
            typing.removeValue(forKey: .folioAlt)
            typing.removeValue(forKey: .attachment)
            editor.typingAttributes = typing
            parent.actions.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            let raw = editor.typingAttributes[.folioBlock] as? String ?? ""
            parent.actions.style = FormattedBlock.Style(rawValue: raw) ?? .paragraph
            var typing = editor.typingAttributes
            for key in [NSAttributedString.Key.folioMarker, .folioImage, .folioAlt, .attachment] {
                typing.removeValue(forKey: key)
            }
            editor.typingAttributes = typing
            parent.actions.refresh()
        }

        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol,
                      in cellFrame: NSRect, at charIndex: Int) {
            guard let reference = textView.textStorage?.attribute(.folioImage, at: charIndex, effectiveRange: nil) as? String,
                  let url = parent.resources?.localURL(for: reference) else {
                parent.onError("This image is missing or outside this note's resource folder.")
                return
            }
            guard let onImage = parent.onImage else {
                parent.onError("The image viewer is not available.")
                return
            }
            onImage(url)
        }
    }
}
