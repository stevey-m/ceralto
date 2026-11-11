import Foundation
import SwiftSoup

public struct FormattedRun: Equatable, Sendable {
    public var text = ""
    public var bold = false
    public var italic = false
    public var underline = false
    public var struck = false
    public var code = false
    public var link: String?
    public var image: String?
    public var fontSize: Double?

    public init(text: String = "") { self.text = text }
}

public struct FormattedBlock: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        case paragraph, heading1, heading2, bullet, ordered, checklist, quote, code, table

        public var title: String {
            switch self {
            case .paragraph: "Body"
            case .heading1: "Title"
            case .heading2: "Heading"
            case .bullet: "Bullet list"
            case .ordered: "Numbered list"
            case .checklist: "Checklist"
            case .quote: "Quote"
            case .code: "Code"
            case .table: "Table"
            }
        }
    }

    public var style: Style
    public var runs: [FormattedRun]
    public var listDepth: Int
    public var checked: Bool
    public var orderedNumber: Int
    public var tableRows: [[FormattedTableCell]]

    public init(style: Style = .paragraph, runs: [FormattedRun], listDepth: Int = 0,
                checked: Bool = false, orderedNumber: Int = 1,
                tableRows: [[FormattedTableCell]] = []) {
        self.style = style
        self.runs = runs
        self.listDepth = max(0, listDepth)
        self.checked = checked
        self.orderedNumber = max(1, orderedNumber)
        self.tableRows = tableRows
    }
}

public struct FormattedTableCell: Equatable, Sendable {
    public var runs: [FormattedRun]
    public init(runs: [FormattedRun]) { self.runs = runs }
}

/// Semantic writing blocks shared by the native editor and portable Markdown.
public struct FormattedPage: Equatable, Sendable {
    public var blocks: [FormattedBlock]

    public init(blocks: [FormattedBlock]) { self.blocks = blocks }

    public init(markdown: String) throws {
        try self.init(html: PreviewDocument.markdownHTML(markdown))
    }

    public init(html: String) throws {
        let document = try SwiftSoup.parseBodyFragment(html)
        try document.select("script,style,iframe,object,embed,svg,math").remove()
        guard try document.select("hr,details,h3,h4,h5,h6").isEmpty(),
              try document.select("input:not([type=checkbox])").isEmpty() else {
            throw JoplinImportError.invalid("This note contains unsupported Markdown. Use the Markdown source editor to preserve all of its structure.")
        }
        var result: [FormattedBlock] = []
        func visitList(_ list: Element, depth: Int) throws {
            let ordered = list.tagName() == "ol"
            let listType = try list.attr("type")
            guard !ordered || listType.isEmpty || listType == "1" else {
                throw JoplinImportError.invalid("This ordered list uses a non-decimal marker that Compose cannot preserve; use Markdown Source.")
            }
            let start = max(1, Int(try list.attr("start")) ?? 1)
            var nextNumber = start
            for item in list.children().array().filter({ $0.tagName() == "li" }) {
                let number = Int(try item.attr("value")) ?? nextNumber
                nextNumber = number + 1
                let directElements = item.children().array()
                let nested = directElements.filter { ["ul", "ol"].contains($0.tagName()) }
                let wrappers = directElements.filter { ["p", "div"].contains($0.tagName()) }
                let blockTags: Set<String> = ["blockquote", "pre", "table", "h1", "h2", "h3", "h4", "h5", "h6",
                    "hr", "details", "figure", "section", "article", "aside", "header", "footer", "dl", "li"]
                let hasLooseContent = try item.getChildNodes().contains { node in
                    if let text = node as? TextNode {
                        return !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    guard let element = node as? Element else { return false }
                    if ["p", "div", "ul", "ol"].contains(element.tagName()) { return false }
                    let type = try element.attr("type")
                    return !(element.tagName() == "input" && type == "checkbox")
                }
                let wrapperHasBlocks = try wrappers.contains { wrapper in
                    try wrapper.select("p,div,ul,ol,blockquote,pre,table,h1,h2,h3,h4,h5,h6,hr,li").array().contains { $0 !== wrapper }
                }
                guard wrappers.count <= 1, !wrapperHasBlocks,
                      !(wrappers.count == 1 && hasLooseContent),
                      !directElements.contains(where: { blockTags.contains($0.tagName()) }) else {
                    throw JoplinImportError.invalid("This list item has multiple or unsupported blocks; use Markdown Source to preserve it.")
                }
                // cmark-gfm places a loose task checkbox before the item's paragraph; HTML clipboards may nest it inside.
                let checkbox = ([item] + wrappers).lazy.compactMap { host in
                    host.children().array().first { $0.tagName() == "input" && (try? $0.attr("type")) == "checkbox" }
                }.first
                let isChecklist = checkbox != nil
                let style: FormattedBlock.Style = checkbox == nil ? (ordered ? .ordered : .bullet) : .checklist
                let checked = checkbox?.hasAttr("checked") ?? false
                try checkbox?.remove()
                for child in nested { try child.remove() }
                var runs = try Self.runs(in: item)
                if isChecklist, let first = runs.indices.first, runs[first].text.hasPrefix(" ") {
                    runs[first].text.removeFirst()
                }
                while let last = runs.indices.last, !runs[last].code, runs[last].image == nil,
                      runs[last].text != "\n", runs[last].text.last?.isNewline == true {
                    runs[last].text.removeLast()
                    if runs[last].text.isEmpty { runs.removeLast() }
                }
                if runs.count == 1, runs[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runs = [] }
                result.append(FormattedBlock(style: style, runs: runs, listDepth: depth,
                    checked: checked, orderedNumber: number))
                for child in nested { try visitList(child, depth: depth + 1) }
            }
        }
        func visitTable(_ table: Element) throws {
            guard try table.select("table table,caption,colgroup,col,tfoot,img,ul,ol,p,div,blockquote,pre,hr,[rowspan],[colspan],[align]").isEmpty() else {
                throw JoplinImportError.invalid("This table uses merged, aligned or block cells that Compose cannot preserve; use Markdown Source.")
            }
            var rows: [[FormattedTableCell]] = []
            var headerRows: [Bool] = []
            for row in try table.select("tr") {
                let cells = row.children().array().filter { ["th", "td"].contains($0.tagName()) }
                guard row.children().array().allSatisfy({ ["th", "td"].contains($0.tagName()) }) else {
                    throw JoplinImportError.invalid("This table contains unsupported cell content; use Markdown Source.")
                }
                if !cells.isEmpty {
                    headerRows.append(cells.allSatisfy { $0.tagName() == "th" })
                    rows.append(try cells.map { FormattedTableCell(runs: try Self.runs(in: $0)) })
                }
            }
            guard !rows.isEmpty, let width = rows.first?.count, width > 0,
                  rows.allSatisfy({ $0.count == width }),
                  headerRows.first == true, headerRows.dropFirst().allSatisfy({ !$0 }) else {
                throw JoplinImportError.invalid("This table is malformed or has inconsistent columns; use Markdown Source to preserve it.")
            }
            result.append(FormattedBlock(style: .table, runs: [], tableRows: rows))
        }
        func visit(_ node: Node) throws {
            guard let element = node as? Element else {
                if let text = node as? TextNode, !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(FormattedBlock(runs: [FormattedRun(text: text.getWholeText())]))
                }
                return
            }
            if element.tagName() == "table" { try visitTable(element); return }
            if ["ul", "ol"].contains(element.tagName()) { try visitList(element, depth: 0); return }
            let style: FormattedBlock.Style?
            switch element.tagName() {
            case "p": style = .paragraph
            case "h1": style = .heading1
            case "h2": style = .heading2
            case "li": style = .bullet
            case "blockquote": style = .quote
            case "pre": style = .code
            default: style = nil
            }
            if let style {
                var runs = try Self.runs(in: element)
                if style == .code, let last = runs.indices.last, runs[last].text.hasSuffix("\n") {
                    runs[last].text.removeLast()
                }
                result.append(FormattedBlock(style: style,
                    runs: runs.count == 1 && runs[0].text == "\n" ? [] : runs))
            } else if element.tagName() == "img" {
                result.append(FormattedBlock(runs: try Self.runs(in: element)))
            } else {
                for child in element.getChildNodes() { try visit(child) }
            }
        }
        if let body = document.body() {
            for child in body.getChildNodes() { try visit(child) }
        }
        blocks = result
    }

    public func html() -> String {
        var index = 0
        var output: [String] = []
        func renderList(depth: Int, style: FormattedBlock.Style) -> String {
            let tag = style == .ordered ? "ol" : "ul"
            let start = style == .ordered && index < blocks.count ? blocks[index].orderedNumber : 1
            var items: [String] = []
            while index < blocks.count, blocks[index].listDepth == depth, blocks[index].style == style {
                let block = blocks[index]
                index += 1
                var text = Self.inlineHTML(block.runs)
                if style == .checklist {
                    text = "<input type=\"checkbox\" disabled\(block.checked ? " checked" : "")> " + text
                }
                if index < blocks.count, blocks[index].listDepth > depth {
                    text += renderList(depth: blocks[index].listDepth, style: blocks[index].style)
                }
                items.append("<li>\(text)</li>")
            }
            let startAttribute = style == .ordered && start > 1 ? " start=\"\(start)\"" : ""
            return "<\(tag)\(startAttribute)>\(items.joined())</\(tag)>"
        }
        while index < blocks.count {
            let block = blocks[index]
            if [.bullet, .ordered, .checklist].contains(block.style) {
                output.append(renderList(depth: block.listDepth, style: block.style))
                continue
            }
            index += 1
            let text = Self.inlineHTML(block.runs)
            switch block.style {
            case .paragraph: output.append("<p>\(text.isEmpty ? "<br>" : text)</p>")
            case .heading1: output.append("<h1>\(text)</h1>")
            case .heading2: output.append("<h2>\(text)</h2>")
            case .quote: output.append("<blockquote>\(text)</blockquote>")
            case .code: output.append("<pre>\(text)</pre>")
            case .table:
                let rows = block.tableRows.enumerated().map { rowIndex, row in
                    "<tr>" + row.map { cell in
                        let tag = rowIndex == 0 ? "th" : "td"
                        return "<\(tag)>\(Self.inlineHTML(cell.runs))</\(tag)>"
                    }.joined() + "</tr>"
                }
                let header = rows.first ?? ""
                output.append("<table><thead>\(header)</thead><tbody>\(rows.dropFirst().joined())</tbody></table>")
            case .bullet, .ordered, .checklist: break
            }
        }
        return output.joined(separator: "\n")
    }

    private static func inlineHTML(_ runs: [FormattedRun]) -> String {
        merged(runs).map { run -> String in
            if let image = run.image { return "<img src=\"\(escape(image))\" alt=\"\(escape(run.text))\">" }
            var text = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.code { text = "<code>\(text)</code>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.underline { text = "<u>\(text)</u>" }
            if run.struck { text = "<s>\(text)</s>" }
            if let link = run.link, allowedLink(link) { text = "<a href=\"\(escape(link))\">\(text)</a>" }
            if let size = run.fontSize { text = "<span style=\"font-size:\(size)px\">\(text)</span>" }
            return text
        }.joined()
    }

    public func markdown() -> String {
        let rendered = blocks.enumerated().map { blockIndex, block in
            func listIndent() -> String {
                var widths: [Int] = []
                for prior in blocks.prefix(blockIndex) {
                    guard [.bullet, .ordered, .checklist].contains(prior.style) else {
                        widths.removeAll()
                        continue
                    }
                    let depth = prior.listDepth
                    if widths.count > depth + 1 { widths = Array(widths.prefix(depth + 1)) }
                    while widths.count < depth { widths.append(2) }
                    let markerWidth = prior.style == .ordered ? "\(prior.orderedNumber). ".count : 2
                    if widths.count == depth { widths.append(markerWidth) }
                    else { widths[depth] = markerWidth }
                }
                return String(repeating: " ", count: widths.prefix(block.listDepth).reduce(0, +))
            }
            if block.style == .code {
                if block.runs.contains(where: { $0.fontSize != nil }) {
                    return "<pre>\(Self.inlineHTML(block.runs))</pre>"
                }
                let text = block.runs.map(\.text).joined()
                let fence = String(repeating: "`", count: max(3, Self.longestBackticks(in: text) + 1))
                return "\(fence)\n\(text)\n\(fence)"
            }
            let contents = Self.merged(block.runs).map { run -> String in
                if let image = run.image {
                    return "![\(Self.markdownText(run.text))](\(Self.markdownURL(image)))"
                }
                if run.fontSize != nil {
                    return Self.inlineHTML([run]).replacingOccurrences(of: "|", with: "&#124;")
                }
                let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return run.text }
                let prefix = String(run.text.prefix(while: \.isWhitespace))
                let suffix = String(run.text.reversed().prefix(while: \.isWhitespace).reversed())
                var text = Self.markdownText(trimmed)
                if run.code {
                    let delimiter = String(repeating: "`", count: Self.longestBackticks(in: run.text) + 1)
                    text = "\(delimiter) \(trimmed) \(delimiter)"
                }
                if run.bold { text = "**\(text)**" }
                if run.italic { text = "*\(text)*" }
                if run.struck { text = "~~\(text)~~" }
                if run.underline { text = "<u>\(text)</u>" }
                if let link = run.link, Self.allowedLink(link) { text = "[\(text)](\(Self.markdownURL(link)))" }
                return prefix + text + suffix
            }.joined()
            switch block.style {
            case .paragraph: return contents.isEmpty ? "<p><br></p>" : contents
            case .heading1: return "# \(contents)"
            case .heading2: return "## \(contents)"
            case .bullet: return listIndent() + "- " + contents
            case .ordered: return listIndent() + "\(block.orderedNumber). " + contents
            case .checklist: return listIndent() + (block.checked ? "- [x] " : "- [ ] ") + contents
            case .quote: return "> " + contents.replacingOccurrences(of: "\n", with: "\n> ")
            case .code: return contents
            case .table:
                guard let header = block.tableRows.first else { return "" }
                func row(_ cells: [FormattedTableCell]) -> String {
                    "| " + cells.map { cell in
                        Self.merged(cell.runs).map { run in
                            if run.fontSize != nil {
                                return Self.inlineHTML([run]).replacingOccurrences(of: "|", with: "&#124;")
                            }
                            var value = Self.markdownText(run.text)
                            if run.code { value = "`\(value)`" }
                            if run.bold { value = "**\(value)**" }
                            if run.italic { value = "*\(value)*" }
                            if run.struck { value = "~~\(value)~~" }
                            if run.underline { value = "<u>\(value)</u>" }
                            if let link = run.link, Self.allowedLink(link) { value = "[\(value)](\(Self.markdownURL(link)))" }
                            return value
                        }.joined()
                    }.joined(separator: " | ") + " |"
                }
                return ([row(header), "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"] +
                    block.tableRows.dropFirst().map(row)).joined(separator: "\n")
            }
        }
        return rendered.enumerated().map { index, value in
            guard index > 0 else { return value }
            let previous = blocks[index - 1]
            let current = blocks[index]
            let listStyles: [FormattedBlock.Style] = [.bullet, .ordered, .checklist]
            let adjacentLists = listStyles.contains(previous.style) && listStyles.contains(current.style)
            // CommonMark only lets a nested ordered list interrupt its parent item's text when it starts at 1.
            let nestedOrderedStart = current.style == .ordered && current.orderedNumber != 1 &&
                current.listDepth > previous.listDepth
            return (adjacentLists && !nestedOrderedStart ? "\n" : "\n\n") + value
        }.joined()
    }

    private static func merged(_ runs: [FormattedRun]) -> [FormattedRun] {
        var result: [FormattedRun] = []
        for run in runs {
            if let last = result.last, last.image == nil, run.image == nil {
                var lhs = last
                var rhs = run
                lhs.text = ""
                rhs.text = ""
                if lhs == rhs {
                    result[result.count - 1].text += run.text
                    continue
                }
            }
            result.append(run)
        }
        return result
    }

    private static func markdownText(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">", "!", "~", "|", "#"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        result = result.replacingOccurrences(of: "(?m)^([ \\t]*)([-+=]) ",
                                             with: "$1\\\\$2 ", options: .regularExpression)
        return result.replacingOccurrences(of: "(?m)^([ \\t]*[0-9]+)([.)]) ",
                                           with: "$1\\\\$2 ", options: .regularExpression)
    }

    private static func markdownURL(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\"", with: "%22")
    }

    private static func longestBackticks(in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func allowedLink(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        if let scheme = url.scheme {
            if ["https", "http", "mailto"].contains(scheme.lowercased()) { return true }
            guard scheme.lowercased() == "folio-note", let host = url.host,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.path.isEmpty, url.query == nil, url.fragment == nil,
                  let id = UUID(uuidString: host), id.uuidString.lowercased() == host.lowercased() else { return false }
            return true
        }
        return !value.hasPrefix("//")
    }

    public static func fontSizeDeclaration(in style: String) -> String? {
        style.split(separator: ";").compactMap { part -> String? in
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "font-size" else { return nil }
            return pair[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.last
    }

    public static func fontSize(in style: String) -> Double? {
        guard let value = fontSizeDeclaration(in: style),
              value.hasSuffix("px") || value.hasSuffix("pt"),
              let number = Double(value.dropLast(2).trimmingCharacters(in: .whitespaces)),
              number.isFinite else { return nil }
        let size = value.hasSuffix("pt") ? number * 4 / 3 : number
        return (1...512).contains(size) ? size : nil
    }

    private static func runs(in node: Node, inheriting inherited: FormattedRun = FormattedRun()) throws -> [FormattedRun] {
        if let text = node as? TextNode {
            var run = inherited
            run.text = text.getWholeText()
            if !run.code && run.text.contains("\n") &&
                run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
            return [run]
        }
        guard let element = node as? Element else { return [] }
        var run = inherited
        let style = try element.attr("style")
        if fontSizeDeclaration(in: style) != nil {
            guard let size = fontSize(in: style) else {
                throw JoplinImportError.invalid("This font size cannot be preserved in Compose. Use source editing; absolute sizes from 1 to 512 screen points are supported.")
            }
            run.fontSize = size
        }
        switch element.tagName() {
        case "strong", "b": run.bold = true
        case "em", "i": run.italic = true
        case "u": run.underline = true
        case "s", "del": run.struck = true
        case "code": run.code = true
        case "a":
            let href = try element.attr("href")
            if allowedLink(href) { run.link = href }
        case "img":
            run.image = try element.attr("src")
            run.text = try element.attr("alt")
            return [run]
        case "br":
            run.text = "\n"
            return [run]
        default: break
        }
        return try element.getChildNodes().flatMap { try runs(in: $0, inheriting: run) }
    }
}
