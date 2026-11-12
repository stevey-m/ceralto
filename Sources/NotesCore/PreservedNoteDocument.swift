import Foundation
import SwiftSoup
import cmark_gfm

/// Projects text into editable spans while retaining the original source around every edit.
public struct PreservedNoteDocument: Sendable {
    public let source: String
    public let renderedHTML: String
    public var editableIDs: Set<String> { Set(segments.keys) }

    private struct Segment: Sendable {
        let range: Range<Int>
        let markdown: Bool
    }
    private var segments: [String: Segment]

    public init(source: String, format: NoteFormat) throws {
        self.source = source
        let bytes = Array(source.utf8)
        let prefix = UUID().uuidString.lowercased()
        var mappings: [String: Segment] = [:]
        func identifier() -> String { "\(prefix)-\(mappings.count)" }
        func annotateHTML(_ html: String, range: Range<Int>) throws -> String {
            let input = Array(html.utf8)
            var output: [UInt8] = []
            var cursor = 0
            for location in try Self.htmlTextRanges(in: input) {
                let id = identifier()
                mappings[id] = Segment(range: (range.lowerBound + location.lowerBound)..<(range.lowerBound + location.upperBound),
                                       markdown: false)
                output.append(contentsOf: input[cursor..<location.lowerBound])
                output.append(contentsOf: "<span data-ceralto-edit=\"\(id)\">".utf8)
                let text = input[location]
                if text.isEmpty { output.append(contentsOf: "<br>".utf8) }
                else { output.append(contentsOf: text) }
                output.append(contentsOf: "</span>".utf8)
                cursor = location.upperBound
            }
            output.append(contentsOf: input[cursor...])
            return String(decoding: output, as: UTF8.self)
        }
        if format.usesHTML {
            renderedHTML = try annotateHTML(source, range: 0..<bytes.count)
        } else {
            var lineStarts = [0]
            for (index, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(index + 1) }
            func range(of node: UnsafeMutablePointer<cmark_node>) throws -> Range<Int> {
                let first = Int(cmark_node_get_start_line(node)) - 1
                let last = Int(cmark_node_get_end_line(node)) - 1
                guard lineStarts.indices.contains(first), lineStarts.indices.contains(last) else {
                    throw NoteWorkflowError("This Markdown text has no reliable source position. Its source has not been changed.")
                }
                let start = lineStarts[first] + max(0, Int(cmark_node_get_start_column(node)) - 1)
                let end = lineStarts[last] + Int(cmark_node_get_end_column(node))
                guard start < end, end <= bytes.count,
                      String(bytes: bytes[start..<end], encoding: .utf8) != nil else {
                    throw NoteWorkflowError("This Markdown text has an invalid source position. Its source has not been changed.")
                }
                return start..<end
            }
            renderedHTML = try PreviewDocument.renderMarkdown(source, hardLineBreaks: format == .markdown) { root in
                func visit(_ node: UnsafeMutablePointer<cmark_node>) throws {
                    let type = cmark_node_get_type(node)
                    // Image descriptions and code literals must not acquire HTML inside their Markdown syntax.
                    if type == CMARK_NODE_IMAGE || type == CMARK_NODE_CODE || type == CMARK_NODE_CODE_BLOCK { return }
                    if type == CMARK_NODE_HTML_BLOCK {
                        let location = try range(of: node)
                        let original = String(decoding: bytes[location], as: UTF8.self)
                        let annotated = try annotateHTML(original, range: location)
                        cmark_node_set_literal(node, annotated)
                        return
                    }
                    if type == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        let location = try range(of: node)
                        let id = identifier()
                        mappings[id] = Segment(range: location, markdown: true)
                        guard let replacement = cmark_node_new(CMARK_NODE_HTML_INLINE) else {
                            throw NoteWorkflowError("The editable text could not be prepared.")
                        }
                        let html = "<span data-ceralto-edit=\"\(id)\">\(FormattedPage.escape(text))</span>"
                        cmark_node_set_literal(replacement, html)
                        guard cmark_node_insert_before(node, replacement) != 0 else {
                            cmark_node_free(replacement)
                            throw NoteWorkflowError("The editable text could not be placed.")
                        }
                        cmark_node_unlink(node)
                        cmark_node_free(node)
                        return
                    }
                    var child = cmark_node_first_child(node)
                    while let current = child {
                        child = cmark_node_next(current)
                        try visit(current)
                    }
                }
                try visit(root)
            }
        }
        segments = mappings
        guard !mappings.isEmpty else {
            throw NoteWorkflowError("This note has no safely editable text. Use Source for code or structural changes.")
        }
    }

    /// Validates the complete edit set before constructing a new source string.
    public func applying(_ changes: [String: String]) throws -> String {
        guard !changes.isEmpty else { return source }
        var validated: [String: String] = [:]
        for (id, html) in changes {
            guard segments[id] != nil else { throw NoteWorkflowError("The text selection belongs to an older note. Reopen this note before editing.") }
            validated[id] = try Self.inlineHTML(html, markdown: segments[id]?.markdown == true)
        }
        let bytes = Array(source.utf8)
        var patches: [(Range<Int>, String)] = []
        for (id, html) in validated {
            guard let segment = segments[id] else { throw NoteWorkflowError("The text selection is no longer available.") }
            patches.append((segment.range, segment.markdown ? "<span>\(html)</span>" : html))
        }
        patches.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result: [UInt8] = []
        var offset = 0
        for (range, replacement) in patches {
            guard range.lowerBound >= offset else { throw NoteWorkflowError("Overlapping layout edits could not be saved.") }
            result.append(contentsOf: bytes[offset..<range.lowerBound])
            result.append(contentsOf: replacement.utf8)
            offset = range.upperBound
        }
        result.append(contentsOf: bytes[offset...])
        guard let output = String(bytes: result, encoding: .utf8) else {
            throw NoteWorkflowError("The edited note could not be encoded without losing text.")
        }
        return output
    }

    // Locate text lexically rather than reserializing an HTML DOM: even valid HTML
    // parsers insert tbody/document wrappers and normalize untouched attributes.
    private static func htmlTextRanges(in bytes: [UInt8]) throws -> [Range<Int>] {
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        var result: [Range<Int>] = []
        var stack: [(tag: String, contentStart: Int)] = []
        var suppressed: [String] = []
        let protected: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math",
                                      "head", "textarea", "select", "button", "form"]
        let rawText: Set<String> = ["script", "style", "textarea", "title"]
        let emptyBlocks: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "td", "th"]
        var cursor = 0
        var textStart = 0
        func appendText(until end: Int) {
            if suppressed.isEmpty, textStart < end,
               !String(decoding: bytes[textStart..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(textStart..<end)
            }
        }
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            if bytes[cursor...].starts(with: [60, 33, 45, 45]) {
                appendText(until: cursor)
                var end = cursor + 4
                while end + 2 < bytes.count, !bytes[end...].starts(with: [45, 45, 62]) { end += 1 }
                guard end + 2 < bytes.count else { throw NoteWorkflowError("This HTML comment is incomplete. Use Source to repair it before visual editing.") }
                cursor = end + 3
                textStart = cursor
                continue
            }
            let closing = cursor + 1 < bytes.count && bytes[cursor + 1] == 47
            let nameStart = cursor + (closing ? 2 : 1)
            guard nameStart < bytes.count else { cursor += 1; continue }
            let first = bytes[nameStart]
            guard (65...90).contains(first) || (97...122).contains(first) || first == 33 || first == 63 else {
                cursor += 1
                continue
            }
            appendText(until: cursor)
            var nameEnd = nameStart
            while nameEnd < bytes.count,
                  (65...90).contains(bytes[nameEnd]) || (97...122).contains(bytes[nameEnd]) ||
                    (48...57).contains(bytes[nameEnd]) || [45, 58].contains(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self).lowercased()
            var end = nameEnd
            var quote: UInt8?
            while end < bytes.count {
                let byte = bytes[end]
                if byte == quote { quote = nil }
                else if quote == nil, byte == 34 || byte == 39 { quote = byte }
                else if quote == nil, byte == 62 { break }
                end += 1
            }
            guard end < bytes.count else { throw NoteWorkflowError("An HTML tag is incomplete. Use Source to repair it before visual editing.") }
            if closing {
                if let index = stack.lastIndex(where: { $0.tag == name }) {
                    let frame = stack[index]
                    if suppressed.isEmpty, emptyBlocks.contains(name) {
                        let contents = String(decoding: bytes[frame.contentStart..<cursor], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if contents.isEmpty || ["<br>", "<br/>", "<br />"].contains(contents) {
                            result.append(frame.contentStart..<cursor)
                        }
                    }
                    stack.removeSubrange(index...)
                }
                if let index = suppressed.lastIndex(of: name) { suppressed.removeSubrange(index...) }
            } else if !name.isEmpty {
                stack.append((name, end + 1))
                if protected.contains(name), name != "embed" { suppressed.append(name) }
                if rawText.contains(name) {
                    let needle = Array("</\(name)".utf8)
                    var close = end + 1
                    while close < lower.count, !lower[close...].starts(with: needle) { close += 1 }
                    guard close < lower.count else { throw NoteWorkflowError("An HTML text container is incomplete. Use Source to repair it before visual editing.") }
                    cursor = close
                    textStart = close
                    continue
                }
            }
            cursor = end + 1
            textStart = cursor
        }
        appendText(until: bytes.count)
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func inlineHTML(_ html: String, markdown: Bool) throws -> String {
        guard html.utf8.count <= 4 * 1_024 * 1_024 else { throw NoteWorkflowError("Paste smaller text selections (under 4 MB) into imported layouts.") }
        let document = try SwiftSoup.parseBodyFragment(html)
        document.outputSettings().prettyPrint(pretty: false)
        for element in try document.select("*") where !["#root", "html", "head", "body"].contains(element.tagName()) {
            guard ["span", "b", "strong", "i", "em", "u", "s", "strike", "del", "br"].contains(element.tagName()),
                  element.getAttributes()?.asList().allSatisfy({ $0.getKey() == "style" }) ?? true else {
                throw NoteWorkflowError("Paste plain text into imported layouts. Images and structural changes use Add Attachments or Source.")
            }
            if element.hasAttr("style") {
                let style = try element.attr("style")
                let safe = FormattedPage.safeInlineStyle(style)
                guard !safe.isEmpty, safe.split(separator: ";").count ==
                    style.split(separator: ";").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count else {
                    throw NoteWorkflowError("This text style cannot be saved safely.")
                }
                try element.attr("style", safe)
            }
        }
        guard let body = document.body() else { throw NoteWorkflowError("The edited text is unavailable.") }
        func serialize(_ node: Node) throws -> String {
            if let text = node as? TextNode {
                var output = FormattedPage.escape(text.getWholeText())
                if markdown {
                    for character in ["*", "_", "`", "[", "]", "\\", "~", "|"] {
                        let scalar = character.unicodeScalars.first!.value
                        output = output.replacingOccurrences(of: character, with: "&#\(scalar);")
                    }
                }
                return output
            }
            guard let element = node as? Element else { throw NoteWorkflowError("Only visible text and inline formatting can be pasted here.") }
            let tag = element.tagName()
            if tag == "br" { return "<br>" }
            let style = try element.attr("style")
            let attributes = style.isEmpty ? "" : " style=\"\(FormattedPage.escape(style))\""
            return "<\(tag)\(attributes)>\(try element.getChildNodes().map(serialize).joined())</\(tag)>"
        }
        return try body.getChildNodes().map(serialize).joined()
    }
}
