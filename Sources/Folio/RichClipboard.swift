import AppKit
import NotesCore
import SwiftSoup
import UniformTypeIdentifiers

@MainActor
enum RichClipboard {
    static let deltosHTML = NSPasteboard.PasteboardType("dev.folio.notes.rich-html")
    static let maximumBytes = 32 * 1024 * 1024

    struct Content {
        var page: FormattedPage
        var images: [(name: String, data: Data)]
    }

    static func read(_ board: NSPasteboard) throws -> Content? {
        if let html = board.string(forType: deltosHTML) {
            guard html.utf8.count <= maximumBytes else { throw NoteWorkflowError("The formatted clipboard is too large.") }
            // HTML is parsed, never loaded in WebKit or AppKit's network-capable HTML importer.
            return try fromHTML(html)
        }
        for (type, format) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd),
                               (.rtf, .rtf)] {
            if type == .rtf, let html = board.string(forType: .html) {
                guard html.utf8.count <= maximumBytes else { throw NoteWorkflowError("The formatted clipboard is too large.") }
                return try fromHTML(html)
            }
            if let data = board.data(forType: type) {
                guard data.count <= maximumBytes else { throw NoteWorkflowError("The formatted clipboard is too large.") }
                let attributed = try NSAttributedString(data: data,
                    options: [.documentType: format], documentAttributes: nil)
                return try fromAttributed(attributed)
            }
        }
        return nil
    }

    static func fromHTML(_ html: String) throws -> Content {
        let document = try SwiftSoup.parseBodyFragment(html)
        document.outputSettings().prettyPrint(pretty: false)
        try document.select("script,style,iframe,object,embed,svg,math,meta,link").remove()
        guard try document.select("table,ol,input,video,audio,canvas,details,h3,h4,h5,h6,li li").isEmpty() else {
            throw NoteWorkflowError("This clipboard contains tables, numbered/nested lists or other unsupported structures. Paste and Match Style for text only, or use a Markdown/HTML import to retain the original.")
        }
        var images: [(name: String, data: Data)] = []
        for image in try document.select("img") {
            let source = try image.attr("src")
            guard source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","),
                  source[..<comma].hasSuffix(";base64"),
                  let bytes = Data(base64Encoded: String(source[source.index(after: comma)...])),
                  bytes.count <= maximumBytes, NSBitmapImageRep(data: bytes) != nil else {
                throw NoteWorkflowError("A clipboard image is not embedded or cannot be read. Copy the image itself or attach its original file; remote images are never downloaded.")
            }
            let mime = String(source.dropFirst(5).prefix(while: { $0 != ";" }))
            let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
            let key = "clipboard-image-\(images.count).\(ext)"
            images.append((key, bytes))
            try image.attr("src", key)
        }
        for element in try document.getAllElements().array().reversed() {
            let style = try element.attr("style").lowercased()
            let styles = style.split(separator: ";").reduce(into: [String: String]()) { result, part in
                let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { result[pair[0]] = pair[1] }
            }
            var wrappers: [String] = []
            if let weight = styles["font-weight"], weight == "bold" || (Int(weight) ?? 0) >= 600 { wrappers.append("strong") }
            if styles["font-style"] == "italic" { wrappers.append("em") }
            let decoration = styles["text-decoration"] ?? styles["text-decoration-line"] ?? ""
            if decoration.contains("underline") { wrappers.append("u") }
            if decoration.contains("line-through") { wrappers.append("s") }
            if styles["font-family"]?.contains("monospace") == true { wrappers.append("code") }
            for tag in wrappers { try element.html("<\(tag)>\(element.html())</\(tag)>") }
            if element.tagName() == "div" {
                let hasBlocks = element.getChildNodes().contains {
                    guard let child = $0 as? Element else { return false }
                    return ["p", "div", "h1", "h2", "ul", "blockquote", "pre"].contains(child.tagName())
                }
                if !hasBlocks { try element.tagName("p") }
            }
        }
        guard let body = document.body() else { throw NoteWorkflowError("The clipboard HTML has no readable body.") }
        var normalized = ""
        var inline = ""
        func flushInline() {
            if !inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized += "<p>\(inline)</p>"
            }
            inline = ""
        }
        for node in body.getChildNodes() {
            if let element = node as? Element,
               ["p", "h1", "h2", "ul", "div", "blockquote", "pre"].contains(element.tagName()) {
                flushInline()
                normalized += try node.outerHtml()
            } else {
                inline += try node.outerHtml()
            }
        }
        flushInline()
        let page = try FormattedPage(html: normalized)
        guard !page.blocks.isEmpty else { throw NoteWorkflowError("The formatted clipboard has no supported content.") }
        return Content(page: page, images: images)
    }

    static func fromAttributed(_ value: NSAttributedString) throws -> Content {
        var blocks: [FormattedBlock] = []
        var images: [(name: String, data: Data)] = []
        let string = value.string as NSString
        var start = 0
        while start < value.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let attrs = value.attributes(at: start, effectiveRange: nil)
            let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
            guard paragraph?.textBlocks.isEmpty != false else {
                throw NoteWorkflowError("Clipboard tables are not supported in Compose. Use Paste and Match Style for text only.")
            }
            let lists = paragraph?.textLists ?? []
            guard lists.count <= 1, lists.allSatisfy({ [.disc, .circle, .square].contains($0.markerFormat) }) else {
                throw NoteWorkflowError("Numbered or nested clipboard lists are not supported in Compose. Use Paste and Match Style for text only.")
            }
            let face = attrs[.font] as? NSFont
            let style: FormattedBlock.Style = !lists.isEmpty ? .bullet
                : (face?.pointSize ?? 0) >= 25 ? .heading1
                : (face?.pointSize ?? 0) >= 20 ? .heading2 : .paragraph
            var contentRange = range
            while contentRange.length > 0 && ["\n", "\r"].contains(string.substring(with: NSRange(location: contentRange.upperBound - 1, length: 1))) {
                contentRange.length -= 1
            }
            if !lists.isEmpty {
                let paragraphText = string.substring(with: contentRange) as NSString
                if paragraphText.hasPrefix("\t"), let marker = paragraphText.range(of: "\t", options: [], range: NSRange(location: 1, length: max(0, paragraphText.length - 1))).nonEmpty {
                    let length = marker.upperBound
                    contentRange.location += length
                    contentRange.length -= length
                }
            }
            var runs: [FormattedRun] = []
            var failure: Error?
            value.enumerateAttributes(in: contentRange) { attrs, range, stop in
                do {
                    var run = FormattedRun(text: string.substring(with: range))
                    if let attachment = attrs[.attachment] as? NSTextAttachment {
                        let data: Data
                        let name: String
                        if let wrapper = attachment.fileWrapper, let bytes = wrapper.regularFileContents,
                           NSBitmapImageRep(data: bytes) != nil {
                            data = bytes
                            name = wrapper.preferredFilename ?? "Image.png"
                        } else if let tiff = attachment.image?.tiffRepresentation,
                                  let bitmap = NSBitmapImageRep(data: tiff),
                                  let bytes = bitmap.representation(using: .png, properties: [:]) {
                            data = bytes
                            name = "Image.png"
                        } else {
                            throw NoteWorkflowError("The clipboard contains an attachment that is not an embedded image. Attach its original file instead.")
                        }
                        guard data.count <= maximumBytes else { throw NoteWorkflowError("A clipboard image is too large.") }
                        let characters = string.substring(with: range)
                        guard characters.allSatisfy({ $0 == "\u{fffc}" }) else {
                            throw NoteWorkflowError("The clipboard has an unsupported attachment representation.")
                        }
                        for _ in characters {
                            let key = "clipboard-image-\(images.count).\(URL(fileURLWithPath: name).pathExtension)"
                            images.append((key, data))
                            var imageRun = FormattedRun(text: name)
                            imageRun.image = key
                            runs.append(imageRun)
                        }
                        return
                    } else {
                        if let font = attrs[.font] as? NSFont {
                            let traits = NSFontManager.shared.traits(of: font)
                            run.bold = traits.contains(.boldFontMask)
                            run.italic = traits.contains(.italicFontMask)
                            run.code = traits.contains(.fixedPitchFontMask)
                        }
                        run.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
                        run.struck = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
                        let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
                        if let link, FormattedPage.allowedLink(link) { run.link = link }
                    }
                    runs.append(run)
                } catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            blocks.append(FormattedBlock(style: style, runs: runs))
            start = range.upperBound
        }
        return Content(page: FormattedPage(blocks: blocks), images: images)
    }

    static func write(_ value: NSAttributedString, resources: ImportedResources?, to board: NSPasteboard) throws {
        let page = try FormattedPage(html: NativePageCodec.encode(value))
        var portable = page
        let attributed = NSMutableAttributedString(attributedString:
            try NativePageCodec.decode(page.html(), resources: resources, color: .black))
        var failure: Error?
        attributed.enumerateAttribute(.folioImage, in: NSRange(location: 0, length: attributed.length)) { reference, range, stop in
            guard let reference = reference as? String else { return }
            do {
                guard let url = resources?.localURL(for: reference) else { throw NoteWorkflowError("An image is missing from this note.") }
                let data = try Data(contentsOf: url)
                guard data.count <= maximumBytes, NSBitmapImageRep(data: data) != nil else { throw NoteWorkflowError("A copied image is unsupported or too large.") }
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = url.lastPathComponent
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                attributed.addAttribute(.attachment, value: attachment, range: range)
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        let nativeString = attributed.string as NSString
        var paragraphStart = 0
        while paragraphStart < attributed.length {
            let range = nativeString.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            if attributed.attribute(.folioBlock, at: paragraphStart, effectiveRange: nil) as? String == FormattedBlock.Style.bullet.rawValue {
                let style = (attributed.attribute(.paragraphStyle, at: paragraphStart, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
                attributed.addAttribute(.paragraphStyle, value: style, range: range)
            }
            paragraphStart = range.upperBound
        }
        var markerRanges: [NSRange] = []
        attributed.enumerateAttribute(.folioMarker, in: NSRange(location: 0, length: attributed.length)) { marker, range, _ in
            if marker as? Bool == true { markerRanges.append(range) }
        }
        for range in markerRanges.reversed() { attributed.replaceCharacters(in: range, with: "\t\u{2022}\t") }
        for key in [NSAttributedString.Key.folioBlock, .folioMarker, .folioImage, .folioAlt, .folioCode, .folioBold] {
            attributed.removeAttribute(key, range: NSRange(location: 0, length: attributed.length))
        }
        for block in portable.blocks.indices {
            for run in portable.blocks[block].runs.indices {
                guard let reference = portable.blocks[block].runs[run].image else { continue }
                guard let url = resources?.localURL(for: reference) else { throw NoteWorkflowError("A copied image is missing.") }
                let data = try Data(contentsOf: url)
                guard data.count <= maximumBytes else { throw NoteWorkflowError("A copied image is too large.") }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                portable.blocks[block].runs[run].image = "data:\(mime);base64,\(data.base64EncodedString())"
            }
        }
        let range = NSRange(location: 0, length: attributed.length)
        let rtfd = try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let html = portable.html()
        guard rtfd.count <= maximumBytes, html.utf8.count <= maximumBytes else {
            throw NoteWorkflowError("The formatted selection is too large to copy. Copy a smaller section.")
        }
        let item = NSPasteboardItem()
        item.setData(rtfd, forType: .rtfd)
        if page.blocks.allSatisfy({ $0.runs.allSatisfy { $0.image == nil } }) {
            let rtf = try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            item.setData(rtf, forType: .rtf)
        }
        item.setString(html, forType: .html)
        item.setString(html, forType: deltosHTML)
        item.setString(value.string.replacingOccurrences(of: "\u{fffc}", with: "[Image]"), forType: .string)
        board.clearContents()
        guard board.writeObjects([item]) else { throw NoteWorkflowError("The clipboard could not be written.") }
    }
}

private extension NSRange {
    var nonEmpty: NSRange? { location != NSNotFound && length > 0 ? self : nil }
}
