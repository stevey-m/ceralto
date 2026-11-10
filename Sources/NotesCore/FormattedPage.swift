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

    public init(text: String = "") { self.text = text }
}

public struct FormattedBlock: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        case paragraph, heading1, heading2, bullet, quote, code

        public var title: String {
            switch self {
            case .paragraph: "Body"
            case .heading1: "Title"
            case .heading2: "Heading"
            case .bullet: "Bullet list"
            case .quote: "Quote"
            case .code: "Code"
            }
        }
    }

    public var style: Style
    public var runs: [FormattedRun]

    public init(style: Style = .paragraph, runs: [FormattedRun]) {
        self.style = style
        self.runs = runs
    }
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
        guard try document.select("table,ol,hr,input,details,h3,h4,h5,h6,li li").isEmpty() else {
            throw JoplinImportError.invalid("This note contains advanced Markdown. Use the Markdown source editor to preserve all of its structure.")
        }
        var result: [FormattedBlock] = []
        func visit(_ node: Node) throws {
            guard let element = node as? Element else {
                if let text = node as? TextNode, !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(FormattedBlock(runs: [FormattedRun(text: text.getWholeText())]))
                }
                return
            }
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
        blocks.map { block in
            let contents = Self.merged(block.runs).map { run -> String in
                if let image = run.image {
                    return "<img src=\"\(Self.escape(image))\" alt=\"\(Self.escape(run.text))\">"
                }

                var text = Self.escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
                if run.code { text = "<code>\(text)</code>" }
                if run.bold { text = "<strong>\(text)</strong>" }
                if run.italic { text = "<em>\(text)</em>" }
                if run.underline { text = "<u>\(text)</u>" }
                if run.struck { text = "<s>\(text)</s>" }
                if let link = run.link, Self.allowedLink(link) {
                    text = "<a href=\"\(Self.escape(link))\">\(text)</a>"
                }
                return text
            }.joined()
            let text = contents.isEmpty ? "<br>" : contents
            switch block.style {
            case .paragraph: return "<p>\(text)</p>"
            case .heading1: return "<h1>\(text)</h1>"
            case .heading2: return "<h2>\(text)</h2>"
            case .bullet: return "<ul><li>\(text)</li></ul>"
            case .quote: return "<blockquote>\(text)</blockquote>"
            case .code: return "<pre>\(text)</pre>"
            }
        }.joined(separator: "\n")
    }

    public func markdown() -> String {
        blocks.map { block in
            if block.style == .code {
                let text = block.runs.map(\.text).joined()
                let fence = String(repeating: "`", count: max(3, Self.longestBackticks(in: text) + 1))
                return "\(fence)\n\(text)\n\(fence)"
            }
            let contents = Self.merged(block.runs).map { run -> String in
                if let image = run.image {
                    return "![\(Self.markdownText(run.text))](\(Self.markdownURL(image)))"
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
            case .bullet: return "- " + contents.replacingOccurrences(of: "\n", with: "\n  ")
            case .quote: return "> " + contents.replacingOccurrences(of: "\n", with: "\n> ")
            case .code: return contents
            }
        }.joined(separator: "\n\n")
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
        if let scheme = url.scheme { return ["https", "http", "mailto"].contains(scheme.lowercased()) }
        return !value.hasPrefix("//")
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
