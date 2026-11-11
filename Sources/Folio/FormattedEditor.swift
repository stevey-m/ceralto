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
    static let folioListDepth = Self("FolioListDepth")
    static let folioChecked = Self("FolioChecked")
    static let folioOrderedNumber = Self("FolioOrderedNumber")
    static let folioTableRow = Self("FolioTableRow")
}

@MainActor
enum NativePageCodec {
    static func isList(_ style: FormattedBlock.Style) -> Bool {
        [.bullet, .ordered, .checklist].contains(style)
    }

    static func listMarker(_ style: FormattedBlock.Style, number: Int = 1, checked: Bool = false) -> String {
        switch style {
        case .bullet: "• "
        case .ordered: "\(number). "
        case .checklist: checked ? "☑ " : "☐ "
        default: ""
        }
    }

    static func font(_ family: ReadingFont, size: Double) -> NSFont {
        switch family {
        case .system: .systemFont(ofSize: size)
        case .monospace: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif: NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        }
    }

    static func attributes(style: FormattedBlock.Style, size: Double, family: ReadingFont,
                           color: NSColor, listDepth: Int = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        if isList(style) {
            paragraph.firstLineHeadIndent = CGFloat(max(0, listDepth)) * 22
            paragraph.headIndent = CGFloat(max(0, listDepth) + 1) * 22
        } else if style == .quote {
            paragraph.headIndent = 22
        }
        let scale = style == .heading1 ? 1.8 : style == .heading2 ? 1.35 : 1
        var face = font(style == .code ? .monospace : family, size: size * scale)
        if style == .heading1 || style == .heading2 {
            face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)
        }
        return [.font: face, .foregroundColor: color, .paragraphStyle: paragraph,
                .folioBlock: style.rawValue, .folioBold: false, .folioListDepth: 0,
                .folioChecked: false, .folioOrderedNumber: 1, .folioTableRow: false]
    }

    static func decode(_ html: String, resources: ImportedResources?, size: Double = 16,
                       family: ReadingFont = .system, color: NSColor = .textColor) throws -> NSAttributedString {
        let page = try FormattedPage(html: html)
        let result = NSMutableAttributedString(string: "")
        for (index, block) in page.blocks.enumerated() {
            var base = attributes(style: block.style, size: size, family: family, color: color,
                                  listDepth: block.listDepth)
            base[.folioListDepth] = block.listDepth
            base[.folioChecked] = block.checked
            base[.folioOrderedNumber] = block.orderedNumber
            if isList(block.style) {
                var marker = base
                marker[.folioMarker] = true
                marker[.folioChecked] = block.checked
                marker[.folioOrderedNumber] = block.orderedNumber
                marker[.folioListDepth] = block.listDepth
                let markerText = listMarker(block.style, number: block.orderedNumber, checked: block.checked)
                result.append(NSAttributedString(string: markerText, attributes: marker))
            }
            if block.style == .table {
                for (rowIndex, row) in block.tableRows.enumerated() {
                    if rowIndex > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
                    var rowAttributes = base
                    rowAttributes[.folioTableRow] = true
                    for (column, cell) in row.enumerated() {
                        if column > 0 { result.append(NSAttributedString(string: "\t", attributes: rowAttributes)) }
                        for run in cell.runs {
                            var attrs = rowAttributes
                            var face = attrs[.font] as? NSFont ?? font(family, size: size)
                            if run.code { face = font(.monospace, size: face.pointSize) }
                            if run.bold { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
                            if run.italic { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
                            attrs[.font] = face
                            attrs[.folioBold] = run.bold
                            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                            if run.struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                            if run.code { attrs[.folioCode] = true }
                            if let link = run.link { attrs[.link] = link }
                            result.append(NSAttributedString(string: run.text, attributes: attrs))
                        }
                    }
                }
            } else {
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
        var tableRows: [[FormattedTableCell]] = []
        func appendRuns(_ range: NSRange) -> [FormattedRun] {
            var runs: [FormattedRun] = []
            text.enumerateAttributes(in: range) { attrs, subrange, _ in
                if attrs[.folioMarker] as? Bool == true { return }
                var run = FormattedRun(text: string.substring(with: subrange))
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
            return runs
        }
        var start = 0
        while start < text.length {
            let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
            var length = paragraph.length
            while length > 0 && ["\n", "\r"].contains(string.substring(with: NSRange(location: start + length - 1, length: 1))) {
                length -= 1
            }
            let kind = text.attribute(.folioBlock, at: start, effectiveRange: nil) as? String
            let style = FormattedBlock.Style(rawValue: kind ?? "") ?? .paragraph
            let paragraphRange = NSRange(location: start, length: length)
            if text.attribute(.folioTableRow, at: start, effectiveRange: nil) as? Bool == true {
                var cells: [FormattedTableCell] = []
                var cellStart = paragraphRange.location
                for offset in 0..<paragraphRange.length {
                    let location = paragraphRange.location + offset
                    if string.substring(with: NSRange(location: location, length: 1)) == "\t" {
                        cells.append(FormattedTableCell(runs: appendRuns(NSRange(location: cellStart, length: location - cellStart))))
                        cellStart = location + 1
                    }
                }
                cells.append(FormattedTableCell(runs: appendRuns(NSRange(location: cellStart,
                    length: paragraphRange.upperBound - cellStart))))
                tableRows.append(cells)
            } else {
                if !tableRows.isEmpty {
                    blocks.append(FormattedBlock(style: .table, runs: [], tableRows: tableRows))
                    tableRows = []
                }
                let runs = appendRuns(paragraphRange)
                let checked = text.attribute(.folioChecked, at: start, effectiveRange: nil) as? Bool ?? false
                let depth = text.attribute(.folioListDepth, at: start, effectiveRange: nil) as? Int ?? 0
                let number = text.attribute(.folioOrderedNumber, at: start, effectiveRange: nil) as? Int ?? 1
                blocks.append(FormattedBlock(style: style, runs: runs, listDepth: depth,
                    checked: checked, orderedNumber: number))
            }
            start = paragraph.location + paragraph.length
        }
        if !tableRows.isEmpty { blocks.append(FormattedBlock(style: .table, runs: [], tableRows: tableRows)) }
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
            if NativePageCodec.isList(style) {
                var marker = attrs
                marker[.folioMarker] = true
                editor.insertText(NSAttributedString(string: NativePageCodec.listMarker(style), attributes: marker),
                                  replacementRange: selection)
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
            let orderedNumbers = Dictionary(uniqueKeysWithValues:
                paragraphs.enumerated().map { ($1.location, $0 + 1) })
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
                    let oldStyle = FormattedBlock.Style(rawValue:
                        text.attribute(.folioBlock, at: paragraph.location, effectiveRange: nil) as? String ?? "") ?? .paragraph
                    let oldDepth = text.attribute(.folioListDepth, at: paragraph.location, effectiveRange: nil) as? Int ?? 0
                    if removed > 0 { text.deleteCharacters(in: markerRange) }
                    let body = NSRange(location: paragraph.location, length: paragraph.length - removed)
                    text.enumerateAttributes(in: body) { original, subrange, _ in
                        var updated = original
                        updated[.folioBlock] = attrs[.folioBlock]
                        let depth = NativePageCodec.isList(style)
                            ? (NativePageCodec.isList(oldStyle) ? oldDepth : 0) : 0
                        updated[.paragraphStyle] = NativePageCodec.attributes(style: style,
                            size: editor.pageFontSize, family: editor.pageFont,
                            color: editor.textColor ?? .textColor, listDepth: depth)[.paragraphStyle]
                        updated[.folioListDepth] = depth
                        updated[.folioChecked] = style == .checklist
                            ? (oldStyle == .checklist ? (original[.folioChecked] as? Bool ?? false) : false) : false
                        let number = style == .ordered ? orderedNumbers[paragraph.location] ?? 1
                            : (original[.folioOrderedNumber] as? Int ?? 1)
                        updated[.folioOrderedNumber] = number
                        updated[.font] = Self.face(for: updated, editor: editor)
                        text.setAttributes(updated, range: subrange)
                    }
                    let inserted = NativePageCodec.isList(style) ? NativePageCodec.listMarker(style).utf16.count : 0
                    if inserted > 0 {
                        var marker = attrs
                        marker[.folioMarker] = true
                        marker[.folioListDepth] = NativePageCodec.isList(oldStyle) ? oldDepth : 0
                        marker[.folioChecked] = style == .checklist && oldStyle == .checklist
                            ? (text.attribute(.folioChecked, at: paragraph.location, effectiveRange: nil) as? Bool ?? false) : false
                        marker[.folioOrderedNumber] = orderedNumbers[paragraph.location] ?? 1
                        text.insert(NSAttributedString(string: NativePageCodec.listMarker(style,
                            number: marker[.folioOrderedNumber] as? Int ?? 1,
                            checked: marker[.folioChecked] as? Bool ?? false), attributes: marker), at: paragraph.location)
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
            typing[.folioListDepth] = 0
            typing[.folioChecked] = false
            typing[.folioOrderedNumber] = 1
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

    func indentList(by amount: Int) {
        guard let editor, editor.isEditable, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        let range = (storage.string as NSString).paragraphRange(for: selection)
        var paragraphs: [NSRange] = []
        var start = range.location
        while start < range.upperBound {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
            paragraphs.append(paragraph)
            start = paragraph.upperBound
        }
        editor.editAttributes(name: amount > 0 ? "Indent List" : "Outdent List") { text in
            var previousDepth: Int?
            if let first = paragraphs.first, first.location > 0 {
                let prior = (text.string as NSString).paragraphRange(for: NSRange(location: first.location - 1, length: 0))
                if prior.location < text.length,
                   let kind = text.attribute(.folioBlock, at: prior.location, effectiveRange: nil) as? String,
                   NativePageCodec.isList(FormattedBlock.Style(rawValue: kind) ?? .paragraph) {
                    previousDepth = text.attribute(.folioListDepth, at: prior.location, effectiveRange: nil) as? Int ?? 0
                }
            }
            for paragraph in paragraphs {
                guard paragraph.location < text.length,
                      let kind = text.attribute(.folioBlock, at: paragraph.location, effectiveRange: nil) as? String,
                      NativePageCodec.isList(FormattedBlock.Style(rawValue: kind) ?? .paragraph) else { continue }
                let old = text.attribute(.folioListDepth, at: paragraph.location, effectiveRange: nil) as? Int ?? 0
                let depth = amount > 0
                    ? (previousDepth.map { min(old + amount, $0 + 1) } ?? old)
                    : max(0, old + amount)
                text.addAttribute(.folioListDepth, value: depth, range: paragraph)
                let style = FormattedBlock.Style(rawValue: kind) ?? .bullet
                let paragraphStyle = NativePageCodec.attributes(style: style, size: editor.pageFontSize,
                    family: editor.pageFont, color: editor.textColor ?? .textColor,
                    listDepth: depth)[.paragraphStyle]
                if let paragraphStyle {
                    text.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
                }
                previousDepth = depth
            }
        }
        refresh()
    }

    func insertTable() {
        guard let editor, editor.isEditable else { return }
        let cell = { FormattedTableCell(runs: []) }
        let table = FormattedBlock(style: .table, runs: [], tableRows: [
            [FormattedTableCell(runs: [FormattedRun(text: "Column 1")]),
             FormattedTableCell(runs: [FormattedRun(text: "Column 2")])],
            [cell(), cell()]
        ])
        do {
            let value = try NativePageCodec.decode(FormattedPage(blocks: [table]).html(),
                resources: editor.resources, size: editor.pageFontSize, family: editor.pageFont,
                color: editor.textColor ?? .textColor)
            let selection = editor.selectedRange()
            let source = editor.string as NSString
            let paragraph = NativePageCodec.attributes(style: .paragraph, size: editor.pageFontSize,
                family: editor.pageFont, color: editor.textColor ?? .textColor)
            let addition = NSMutableAttributedString(attributedString: value)
            if selection.location > 0, source.substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n" {
                addition.insert(NSAttributedString(string: "\n", attributes: paragraph), at: 0)
            }
            if selection.upperBound < source.length, source.substring(with: NSRange(location: selection.upperBound, length: 1)) != "\n" {
                addition.append(NSAttributedString(string: "\n", attributes: paragraph))
            }
            editor.editAttributes(name: "Insert Table") { $0.replaceCharacters(in: selection, with: addition) }
            editor.setSelectedRange(NSRange(location: selection.location + addition.length, length: 0))
            refresh()
        } catch { editor.onError?("Could not insert table: \(error.localizedDescription)") }
    }
}

@MainActor
class DocumentTextView: NSTextView {
    var pairDelimiters = false
    var suppressAutomaticEditing = false
    private var writingWidth: CGFloat = 0
    private var writingInset: NSSize?
    private let delimiterPairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]

    func configureWritingWidth(_ width: CGFloat, inset: NSSize) {
        guard writingWidth != width || writingInset != inset else { return }
        writingWidth = width
        writingInset = inset
        setFrameSize(frame.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let writingInset else { return }
        let horizontal = writingWidth > 0 ? max(writingInset.width, (newSize.width - writingWidth) / 2) : writingInset.width
        let inset = NSSize(width: horizontal, height: writingInset.height)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        guard pairDelimiters, !suppressAutomaticEditing, !hasMarkedText(),
              let typed = value as? String, typed.utf16.count == 1,
              replacementRange.location == NSNotFound || replacementRange == selectedRange() else {
            super.insertText(value, replacementRange: replacementRange)
            return
        }
        let range = selectedRange()
        let body = string as NSString
        if range.length == 0, range.location < body.length,
           delimiterPairs.values.contains(typed), body.substring(with: NSRange(location: range.location, length: 1)) == typed {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }
        guard let closing = delimiterPairs[typed] else {
            super.insertText(value, replacementRange: replacementRange)
            return
        }
        let quote = typed == "\"" || typed == "'"
        let before = range.location > 0 ? body.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let after = range.upperBound < body.length ? body.substring(with: NSRange(location: range.upperBound, length: 1)) : ""
        let boundaryAfter = after.isEmpty || after.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
            delimiterPairs.values.contains(after)
        let boundaryBefore = before.isEmpty || before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
            delimiterPairs.keys.contains(before)
        guard range.length > 0 || (boundaryAfter && (!quote || boundaryBefore)) else {
            super.insertText(value, replacementRange: replacementRange)
            return
        }
        let insertion = NSMutableAttributedString(string: typed, attributes: typingAttributes)
        if range.length > 0, let textStorage { insertion.append(textStorage.attributedSubstring(from: range)) }
        insertion.append(NSAttributedString(string: closing, attributes: typingAttributes))
        super.insertText(insertion, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + 1, length: range.length))
        undoManager?.setActionName("Pair Delimiters")
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        let body = string as NSString
        if isEditable, pairDelimiters, !hasMarkedText(), range.length == 0,
           range.location > 0, range.location < body.length,
           let closing = delimiterPairs[body.substring(with: NSRange(location: range.location - 1, length: 1))],
           body.substring(with: NSRange(location: range.location, length: 1)) == closing {
            super.insertText("", replacementRange: NSRange(location: range.location - 1, length: 2))
        } else { super.deleteBackward(sender) }
    }

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
    var focusOnAttach = false
    var markdownShortcuts = false
    var resources: ImportedResources?
    var onImportFiles: (([URL]) throws -> Attachments.Imported)?
    var onError: ((String) -> Void)?
    var onImage: ((URL) -> Void)?
    var pageFontSize = 16.0
    var pageFont = ReadingFont.system

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isEditable else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func insertText(_ value: Any, replacementRange: NSRange) {
        let selection = selectedRange()
        if isEditable, markdownShortcuts, !suppressAutomaticEditing, !hasMarkedText(),
           let typed = value as? String, typed == " ", selection.length == 0,
           replacementRange.location == NSNotFound || replacementRange == selection,
           typingAttributes[.folioTableRow] as? Bool != true,
           typingAttributes[.folioCode] as? Bool != true {
            let paragraph = (string as NSString).paragraphRange(for: selection)
            let prefixRange = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
            let prefix = (string as NSString).substring(with: prefixRange)
            let currentStyle = FormattedBlock.Style(rawValue: typingAttributes[.folioBlock] as? String ?? "") ?? .paragraph
            let shortcuts: [String: FormattedBlock.Style] = [
                "#": .heading1, "##": .heading2, ">": .quote, "-": .bullet, "*": .bullet,
                "1.": .ordered, "- [ ]": .checklist
            ]
            let style = currentStyle == .paragraph ? shortcuts[prefix] :
                (currentStyle == .bullet && prefix == NativePageCodec.listMarker(.bullet) + "[ ]" ? .checklist : nil)
            let suffix = (string as NSString).substring(with: NSRange(location: selection.location,
                                                                      length: paragraph.upperBound - selection.location))
            if let style, suffix.trimmingCharacters(in: .newlines).isEmpty, let storage = textStorage {
                let attrs = NativePageCodec.attributes(style: style, size: pageFontSize,
                    family: pageFont, color: textColor ?? .textColor)
                var markerAttributes = attrs
                markerAttributes[.folioMarker] = true
                let marker = NativePageCodec.isList(style) ? NativePageCodec.listMarker(style) : ""
                breakUndoCoalescing()
                // Snapshot undo also restores the typing style of an empty heading.
                undoManager?.disableUndoRegistration()
                let accepted = shouldChangeText(in: prefixRange, replacementString: marker)
                undoManager?.enableUndoRegistration()
                guard accepted else { return }
                let transformed = NSMutableAttributedString(attributedString: storage)
                transformed.replaceCharacters(in: prefixRange, with: NSAttributedString(string: marker, attributes: markerAttributes))
                restoreShortcutBuffer(transformed, typing: attrs,
                    selection: NSRange(location: prefixRange.location + marker.utf16.count, length: 0))
                breakUndoCoalescing()
                return
            }
        }
        super.insertText(value, replacementRange: replacementRange)
    }

    private func restoreShortcutBuffer(_ value: NSAttributedString, typing: [NSAttributedString.Key: Any], selection: NSRange) {
        guard let storage = textStorage else { return }
        let previous = NSAttributedString(attributedString: storage)
        let previousTyping = typingAttributes
        let previousSelection = selectedRange()
        let restore: @MainActor (PageTextView) -> Void = {
            $0.restoreShortcutBuffer(previous, typing: previousTyping, selection: previousSelection)
        }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { restore(target) }
        }
        undoManager?.setActionName("Markdown Shortcut")
        storage.setAttributedString(value)
        setSelectedRange(selection)
        typingAttributes = typing
        didChangeText()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if openImage(at: point) { return }
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, index < storage.length,
           let kind = storage.attribute(.folioBlock, at: index, effectiveRange: nil) as? String,
           kind == FormattedBlock.Style.checklist.rawValue {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
            let markerRange = NSRange(location: paragraph.location, length: 0)
            var actualMarker = markerRange
            if markerRange.location < storage.length,
               storage.attribute(.folioMarker, at: markerRange.location, effectiveRange: &actualMarker) as? Bool == true,
               index <= actualMarker.upperBound {
                toggleChecklistItem(at: index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func toggleChecklistItem(at index: Int) {
        guard let storage = textStorage, index < storage.length,
              storage.attribute(.folioBlock, at: index, effectiveRange: nil) as? String == FormattedBlock.Style.checklist.rawValue else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
        var markerRange = NSRange(location: paragraph.location, length: 0)
        guard paragraph.location < storage.length,
              storage.attribute(.folioMarker, at: paragraph.location, effectiveRange: &markerRange) as? Bool == true else { return }
        let checked = !(storage.attribute(.folioChecked, at: paragraph.location, effectiveRange: nil) as? Bool ?? false)
        var markerAttributes = storage.attributes(at: markerRange.location, effectiveRange: nil)
        markerAttributes[.folioChecked] = checked
        editAttributes(name: "Toggle Checklist Item") { text in
            text.addAttribute(.folioChecked, value: checked, range: paragraph)
            text.replaceCharacters(in: markerRange, with: NSAttributedString(
                string: checked ? "☑ " : "☐ ", attributes: markerAttributes))
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let storage = textStorage, storage.length > 0 else { super.insertTab(sender); return }
        let selection = selectedRange()
        let paragraph = (storage.string as NSString).paragraphRange(for: selection)
        guard storage.attribute(.folioTableRow, at: paragraph.location, effectiveRange: nil) as? Bool == true else {
            super.insertTab(sender)
            return
        }
        let body = storage.string as NSString
        var next = NSNotFound
        if selection.location < paragraph.upperBound {
            let search = NSRange(location: selection.location, length: paragraph.upperBound - selection.location)
            next = body.range(of: "\t", options: [], range: search).location
        }
        if next != NSNotFound {
            setSelectedRange(NSRange(location: next + 1, length: 0))
        } else {
            let row = body.substring(with: NSRange(location: paragraph.location, length: paragraph.length))
            let columns = max(2, row.filter { $0 == "\t" }.count + 1)
            let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
            insertText(NSAttributedString(string: "\n" + String(repeating: "\t", count: columns - 1),
                                          attributes: attributes), replacementRange: selection)
        }
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
        if NativePageCodec.isList(style), let storage = textStorage, storage.length > 0 {
            let range = (storage.string as NSString).paragraphRange(for: selectedRange())
            let paragraph = storage.attributedSubstring(from: range)
            let visible = paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let empty = switch style {
            case .bullet: visible == "•"
            case .ordered: visible.range(of: #"^\d+\.$"#, options: .regularExpression) != nil
            case .checklist: ["☐", "☑"].contains(visible)
            default: false
            }
            if empty {
                insertText("", replacementRange: range)
                typingAttributes = NativePageCodec.attributes(style: .paragraph, size: pageFontSize,
                    family: pageFont, color: textColor ?? .textColor)
                return
            }
        }
        super.insertNewline(sender)
        if NativePageCodec.isList(style) {
            let depth = typingAttributes[.folioListDepth] as? Int ?? 0
            var attrs = NativePageCodec.attributes(style: style, size: pageFontSize,
                family: pageFont, color: textColor ?? .textColor, listDepth: depth)
            attrs[.folioMarker] = true
            attrs[.folioBlock] = style.rawValue
            attrs[.folioListDepth] = depth
            let number = (typingAttributes[.folioOrderedNumber] as? Int ?? 1) + 1
            attrs[.folioOrderedNumber] = number
            let checked = false
            attrs[.folioChecked] = checked
            insertText(NSAttributedString(string: NativePageCodec.listMarker(style, number: number, checked: checked),
                                          attributes: attrs), replacementRange: selectedRange())
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
        suppressAutomaticEditing = true
        defer { suppressAutomaticEditing = false }
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
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ceralto-paste-\(UUID().uuidString)")
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
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ceralto-rich-paste-\(UUID().uuidString)")
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
    var focusOnAttach = false
    var onChange: (String) -> Void
    var onError: (String) -> Void
    var onImage: (URL) -> Void
    var currentSource: (() -> String)?
    var onImportFiles: (([URL]) throws -> Attachments.Imported)?
    var body: some View {
        NativePageView(html: note.body, resources: resources, size: fontSize, family: family,
                       dracula: dracula, actions: actions, onChange: onChange,
                       onError: onError, onImage: onImage, currentSource: currentSource,
                       onImportFiles: onImportFiles, contentFormat: note.contentFormat,
                       focusOnAttach: focusOnAttach)
    }

    struct LinkEditorPopover: View {
        @Binding var link: String
        let insert: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link to a page").font(.headline)
                TextField("https://", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(insert)
                Button("Insert Link", action: insert).keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 320).folioAppearance()
        }
    }

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

}

struct NoteFormattingControls: View {
    @ObservedObject var actions: FormattingActions
    @ViewState private var addingLink = false
    @ViewState private var link = ""

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(FormattedBlock.Style.allCases.filter { $0 != .table }, id: \.rawValue) { style in
                    Button(style.title) { actions.setStyle(style) }
                }
                Divider()
                Toggle("Bold", isOn: Binding(get: { actions.bold }, set: { _ in actions.toggle(.boldFontMask) }))
                    .keyboardShortcut("b")
                Toggle("Italic", isOn: Binding(get: { actions.italic }, set: { _ in actions.toggle(.italicFontMask) }))
                    .keyboardShortcut("i")
                Toggle("Underline", isOn: Binding(get: { actions.underline }, set: { _ in actions.toggleInline(.underlineStyle) }))
                    .keyboardShortcut("u")
                Button(actions.struck ? "Remove Strikethrough" : "Strikethrough") { actions.toggleInline(.strikethroughStyle) }
                Button(actions.code ? "Remove Inline Code" : "Inline Code") { actions.toggleInline(.folioCode) }
                Divider()
                Button("Decrease List Indent") { actions.indentList(by: -1) }
                Button("Increase List Indent") { actions.indentList(by: 1) }
                Button("Add Link...") { addingLink = true }
                Button("Remove Link") { actions.removeLink() }.disabled(!actions.linked)
            } label: { Image(systemName: "textformat") }
            .menuIndicator(.hidden).fixedSize()
            .help("Text formatting").accessibilityLabel("Text formatting")
            Button { actions.setStyle(actions.style == .checklist ? .paragraph : .checklist) } label: {
                Image(systemName: "checklist")
            }.help("Checklist").accessibilityLabel("Checklist")
            Button { actions.insertTable() } label: { Image(systemName: "tablecells") }
                .help("Insert editable table").accessibilityLabel("Insert editable table")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $addingLink) {
            FormattedEditor.LinkEditorPopover(link: $link) {
                guard actions.addLink(link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                addingLink = false
                link = ""
            }
        }
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
    @ThemeColors private var palette
    @AppStorage("folioTheme") private var selectedTheme = FolioTheme.system.rawValue
    @AppStorage("editorPairDelimiters") private var pairDelimiters = false
    @AppStorage("composeMarkdownShortcuts") private var markdownShortcuts = false
    @AppStorage("writingColumnWidth") private var columnWidth = 0
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
    var contentFormat: NoteFormat = .formatted
    var focusOnAttach = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PageScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = PageTextView(frame: .zero)
        editor.focusOnAttach = focusOnAttach
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
        editor.pairDelimiters = pairDelimiters
        editor.markdownShortcuts = markdownShortcuts
        editor.configureWritingWidth(CGFloat(columnWidth), inset: NSSize(width: 28, height: 28))
        editor.isContinuousSpellCheckingEnabled = spellChecking
        editor.isEditable = isEnabled && coordinator.loadedHTML == html && coordinator.loadedFormat == contentFormat
        editor.isSelectable = isEnabled
        if !isEnabled, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
        editor.pageFont = family
        editor.pageFontSize = size
        let colors = palette ?? (dracula ? .dracula : nil)
        let color = colors.map { NSColor($0.foregroundColor) } ?? .textColor
        let linkColor = selectedTheme == FolioTheme.custom.rawValue ? colors?.accentColor ?? Color.accentColor :
            FolioPalette.accent(dracula ? .dracula : .system, accent: accent,
                                           draculaAccent: draculaAccent, scheme: colorScheme)
        let paletteChanged = coordinator.loadedHTML == nil || coordinator.dracula != dracula ||
            coordinator.linkColor != NSColor(linkColor) || coordinator.palette != colors
        if paletteChanged {
            editor.insertionPointColor = color
            FolioPalette.style(editor, dracula: dracula, palette: colors)
            editor.linkTextAttributes = [
                .foregroundColor: NSColor(linkColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            coordinator.linkColor = NSColor(linkColor)
            coordinator.palette = colors
        }
        // Resource ownership can change during an insertion without replacing the native buffer or its undo history.
        if coordinator.loadedHTML == html && coordinator.loadedFormat == contentFormat && coordinator.size == size &&
            coordinator.family == family && coordinator.dracula == dracula && previousResources == resources {
            coordinator.resources = resources
            if paletteChanged || coordinator.needsRecolor {
                FolioPalette.styleRichText(editor, dracula: dracula, accent: linkColor, palette: colors)
                coordinator.needsRecolor = false
            }
            return
        }
        do {
            let selection = editor.selectedRange()
            let page = try contentFormat.usesHTML ? FormattedPage(html: html) : FormattedPage(markdown: html)
            let decoded = try NativePageCodec.decode(page.html(), resources: resources, size: size, family: family, color: color)
            coordinator.updating = true
            defer { coordinator.updating = false }
            editor.textStorage?.setAttributedString(decoded)
            FolioPalette.styleRichText(editor, dracula: dracula, accent: linkColor, palette: colors)
            coordinator.needsRecolor = false
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
            coordinator.loadedFormat = contentFormat
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
        var loadedFormat: NoteFormat?
        var resources: ImportedResources?
        var size = 0.0
        var family = ReadingFont.system
        var dracula = false
        var linkColor: NSColor?
        var palette: ThemePack?
        var needsRecolor = false
        var updating = false

        init(parent: NativePageView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? PageTextView,
                  let storage = editor.textStorage else { return }
            loadedHTML = NativePageCodec.encode(storage, markdown: !parent.contentFormat.usesHTML)
            needsRecolor = true
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
