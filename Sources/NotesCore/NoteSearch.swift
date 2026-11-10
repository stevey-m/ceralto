import Foundation

public struct NoteSearchResult: Identifiable, Sendable {
    public var id: UUID { note.id }
    public let note: Note
    public let notebook: String
    public let snippet: String
    public let score: Int
}

public enum NoteSearch {
    public static func find(_ query: String, in library: Library, limit: Int = 80) -> [NoteSearchResult] {
        let parsed = NoteQuery(query)
        let terms = parsed.textTerms
        let names = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        return library.notes.compactMap { note -> NoteSearchResult? in
            guard note.deletedAt == nil else { return nil }
            let notebook = names[note.notebookID] ?? ""
            let body = note.textContent
            guard parsed.matches(note, notebook: notebook) else { return nil }
            let score = terms.reduce(0) { total, term in
                total + (note.displayTitle.localizedStandardContains(term) ? 12 : 0)
                    + (notebook.localizedStandardContains(term) ? 4 : 0)
                    + (note.tags.contains { $0.localizedStandardContains(term) } ? 6 : 0)
            }
            return NoteSearchResult(note: note, notebook: notebook,
                                    snippet: snippet(body, terms: terms), score: score)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.note.updatedAt != $1.note.updatedAt { return $0.note.updatedAt > $1.note.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(max(0, limit)).map { $0 }
    }

    private static func snippet(_ body: String, terms: [String]) -> String {
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let match = terms.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min() ?? text.startIndex
        let start = text.index(match, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "..." : "") + text[start..<end] + (end < text.endIndex ? "..." : "")
    }
}
