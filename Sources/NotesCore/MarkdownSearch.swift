import Foundation

public struct MarkdownSearchMatch: Equatable, Identifiable, Sendable {
    public let path: String
    public let excerpt: String
    public var id: String { path }
}

public struct MarkdownSearchReport: Sendable {
    public let matches: [MarkdownSearchMatch]
    public let unreadable: [String]
    public let truncated: Bool
}

extension LiveMarkdownFolder {
    public func search(_ query: String, limit: Int = 200) throws -> MarkdownSearchReport {
        try Task.checkCancellation()
        guard limit > 0 else { throw NoteWorkflowError("The search result limit must be positive.") }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return MarkdownSearchReport(matches: [], unreadable: [], truncated: false) }
        var matches: [MarkdownSearchMatch] = []
        var unreadable: [String] = []
        for entry in try entries() where !entry.isDirectory {
            try Task.checkCancellation()
            let source: MarkdownSource
            do { source = try read(entry.path) }
            catch {
                unreadable.append("\(entry.path): \(error.localizedDescription)")
                continue
            }
            let contains: (String, String) -> Bool = {
                $0.range(of: $1, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard terms.allSatisfy({ contains(entry.path, $0) || contains(source.text, $0) }) else { continue }
            if matches.count == limit {
                return MarkdownSearchReport(matches: matches, unreadable: unreadable, truncated: true)
            }
            let hit = terms.compactMap { source.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
                .min { $0.lowerBound < $1.lowerBound }?.lowerBound ?? source.text.startIndex
            let start = source.text.index(hit, offsetBy: -45, limitedBy: source.text.startIndex) ?? source.text.startIndex
            let end = source.text.index(start, offsetBy: 180, limitedBy: source.text.endIndex) ?? source.text.endIndex
            let excerpt = source.text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            matches.append(MarkdownSearchMatch(path: entry.path, excerpt: excerpt))
        }
        return MarkdownSearchReport(matches: matches, unreadable: unreadable, truncated: false)
    }
}
