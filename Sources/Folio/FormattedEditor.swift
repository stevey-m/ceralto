import AppKit
import NotesCore
import SwiftUI

extension NSAttributedString.Key {
    static let folioBlock = Self("FolioBlock")
    static let folioMarker = Self("FolioMarker")
    static let folioImage = Self("FolioImage")
    static let folioAlt = Self("FolioAlt")
    static let folioCode = Self("FolioCode")
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
        return [.font: face, .foregroundColor: color, .paragraphStyle: paragraph, .folioBlock: style.rawValue]
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
                        run.bold = traits.contains(.boldFontMask)
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

    func toggle(_ trait: NSFontTraitMask) {
        guard let editor else { return }
        let range = editor.selectedRange()
        let current = range.length > 0
            ? editor.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? editor.typingAttributes
            : editor.typingAttributes
        let face = current[.font] as? NSFont ?? .systemFont(ofSize: 16)
        let removing = NSFontManager.shared.traits(of: face).contains(trait)
        if range.length == 0 {
            var typing = editor.typingAttributes
            typing[.font] = removing
                ? NSFontManager.shared.convert(face, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(face, toHaveTrait: trait)
            typing.removeValue(forKey: .folioMarker)
            editor.typingAttributes = typing
        } else {
            editor.editAttributes(name: "Format Text") { storage in
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = value as? NSFont ?? face
                    storage.addAttribute(.font, value: removing
                        ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                        : NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
                }
            }
        }
        editor.window?.makeFirstResponder(editor)
    }

    func setStyle(_ style: FormattedBlock.Style) {
        guard let editor, let storage = editor.textStorage else { return }
        let selection = editor.selectedRange()
        let range = (storage.string as NSString).paragraphRange(for: selection)
        let attrs = NativePageCodec.attributes(style: style, size: editor.pageFontSize,
                                               family: editor.pageFont, color: editor.textColor ?? .textColor)
        if range.length == 0 {
            editor.typingAttributes = attrs
        } else {
            editor.editAttributes(name: "Paragraph Style") { text in
                // Rebuild only the selected paragraphs so list markers remain presentation, not content.
                let part = text.attributedSubstring(from: range)
                let html = NativePageCodec.encode(part)
                do {
                    var page = try FormattedPage(html: html)
                    for index in page.blocks.indices { page.blocks[index].style = style }
                    let replacement = try NativePageCodec.decode(page.html(), resources: editor.resources,
                        size: editor.pageFontSize, family: editor.pageFont, color: editor.textColor ?? .textColor)
                    text.replaceCharacters(in: range, with: replacement)
                    if range.upperBound < text.length && !replacement.string.hasSuffix("\n") {
                        text.insert(NSAttributedString(string: "\n", attributes: attrs), at: range.location + replacement.length)
                    }
                } catch { editor.onError?("Could not format this paragraph: \(error.localizedDescription)") }
            }
        }
        self.style = style
        editor.window?.makeFirstResponder(editor)
    }

    func addLink(_ value: String) {
        guard let editor else { return }
        guard FormattedPage.allowedLink(value), URL(string: value)?.scheme != nil else {
            editor.onError?("Enter a complete http, https, or mailto link.")
            return
        }
        let range = editor.selectedRange()
        if range.length == 0 {
            var attrs = editor.typingAttributes
            attrs[.link] = value
            editor.insertText(NSAttributedString(string: value, attributes: attrs), replacementRange: range)
        } else {
            editor.editAttributes(name: "Add Link") { $0.addAttribute(.link, value: value, range: range) }
        }
        editor.window?.makeFirstResponder(editor)
    }
}

@MainActor
final class PageTextView: NSTextView {
    private let pageUndo = UndoManager()
    override var undoManager: UndoManager? { pageUndo }
    var resources: ImportedResources?
    var onFiles: (([URL]) -> Void)?
    var onError: ((String) -> Void)?
    var pageFontSize = 16.0
    var pageFont = ReadingFont.system

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
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onFiles?(urls)
        } else if let text = board.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        } else {
            onError?("Paste text or copy files in Finder to attach them. Use the paperclip for image files.")
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
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
            let fitted = min(width, max(1, natural.width))
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
    var onChange: (String) -> Void
    var onFiles: ([URL]) -> Void
    var onError: (String) -> Void
    @StateObject private var actions = FormattingActions()
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
                Button { actions.toggle(.italicFontMask) } label: { Image(systemName: "italic") }
                    .keyboardShortcut("i").help("Italic (Command-I)").accessibilityLabel("Italic")
                Button { actions.setStyle(.bullet) } label: { Image(systemName: "list.bullet") }
                    .help("Bullet list").accessibilityLabel("Bullet list")
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
                           dracula: dracula, actions: actions, onChange: onChange, onFiles: onFiles, onError: onError)
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
        actions.addLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
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
    let html: String
    let resources: ImportedResources?
    let size: Double
    let family: ReadingFont
    let dracula: Bool
    let actions: FormattingActions
    var onChange: (String) -> Void
    var onFiles: ([URL]) -> Void
    var onError: (String) -> Void

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
        let coordinator = context.coordinator
        coordinator.parent = self
        editor.resources = resources
        editor.onFiles = onFiles
        editor.onError = onError
        editor.pageFont = family
        editor.pageFontSize = size
        let color = dracula ? NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1) : .textColor
        editor.textColor = color
        editor.insertionPointColor = color
        guard coordinator.loadedHTML != html || coordinator.size != size ||
                coordinator.family != family || coordinator.dracula != dracula || coordinator.resources != resources else { return }
        do {
            let selection = editor.selectedRange()
            let page = try FormattedPage(markdown: html)
            let decoded = try NativePageCodec.decode(page.html(), resources: resources, size: size, family: family, color: color)
            coordinator.updating = true
            defer { coordinator.updating = false }
            editor.textStorage?.setAttributedString(decoded)
            editor.typingAttributes = NativePageCodec.attributes(style: .paragraph, size: size, family: family, color: color)
            editor.setSelectedRange(NSRange(location: min(selection.location, decoded.length), length: 0))
            editor.isEditable = true
            if coordinator.loadedHTML != nil && coordinator.loadedHTML != html { editor.undoManager?.removeAllActions() }
            coordinator.loadedHTML = html
            coordinator.size = size
            coordinator.family = family
            coordinator.dracula = dracula
            coordinator.resources = resources
            editor.setFrameSize(editor.frame.size)
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
        }

        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol,
                      in cellFrame: NSRect, at charIndex: Int) {
            guard let reference = textView.textStorage?.attribute(.folioImage, at: charIndex, effectiveRange: nil) as? String,
                  let url = parent.resources?.localURL(for: reference) else {
                parent.onError("This image is missing or outside this note's resource folder.")
                return
            }
            if !NSWorkspace.shared.open(url) { parent.onError("Could not open the original image.") }
        }
    }
}
