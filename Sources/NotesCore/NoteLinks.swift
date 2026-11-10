import Foundation
import SwiftSoup

public enum NoteLinks {
    public static func targets(in library: Library) -> [String: UUID] {
        let notebooks = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        var groups: [String: Set<UUID>] = [:]
        for note in library.notes where note.deletedAt == nil {
            groups[key(note.displayTitle), default: []].insert(note.id)
            if let notebook = notebooks[note.notebookID] {
                groups[key(notebook + "/" + note.displayTitle), default: []].insert(note.id)
            }
        }
        return groups.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    public static func backlinks(to note: Note, in library: Library) throws -> [Note] {
        let destinations = targets(in: library)
        return try library.notes.filter { candidate in
            guard candidate.id != note.id, candidate.deletedAt == nil else { return false }
            let html = candidate.contentFormat.usesHTML ? candidate.body : try PreviewDocument.markdownHTML(candidate.body)
            let document = try SwiftSoup.parseBodyFragment(html)
            return try textNodes(in: document).contains { node in
                try references(in: node.getWholeText()).contains { destinations[key($0.target)] == note.id }
            }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func linkedBody(_ html: String, targets: [String: UUID]) throws -> String {
        guard !targets.isEmpty else { return html }
        let document = try SwiftSoup.parseBodyFragment(html)
        for node in textNodes(in: document) {
            let text = node.getWholeText()
            let references = try references(in: text)
            guard !references.isEmpty else { continue }
            var output = ""
            var cursor = text.startIndex
            for reference in references {
                output += FormattedPage.escape(String(text[cursor..<reference.range.lowerBound]))
                if let id = targets[key(reference.target)] {
                    output += "<a href=\"folio-note://\(id.uuidString)\">\(FormattedPage.escape(reference.label))</a>"
                } else {
                    output += FormattedPage.escape(String(text[reference.range]))
                }
                cursor = reference.range.upperBound
            }
            output += FormattedPage.escape(String(text[cursor...]))
            try node.before(output)
            try node.remove()
        }
        return try document.body()?.html() ?? ""
    }

    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct Reference {
        let target: String
        let label: String
        let range: Range<String.Index>
    }

    private static func references(in text: String) throws -> [Reference] {
        let pattern = try NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { return nil }
            let parts = text[inner].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = parts.count == 2 ? String(parts[1]) : target
            return Reference(target: target, label: label, range: whole)
        }
    }

    private static func textNodes(in node: Node) -> [TextNode] {
        if let element = node as? Element,
           ["pre", "code", "a", "script", "style"].contains(element.tagName()) { return [] }
        if let text = node as? TextNode { return [text] }
        return node.getChildNodes().flatMap { textNodes(in: $0) }
    }
}
