import Foundation

/// All clauses are combined with AND. Invalid filters match nothing and expose an error for the UI.
public struct NoteQuery: Sendable {
    public private(set) var errorMessage: String?
    public private(set) var textTerms: [String] = []
    private var clauses: [Clause] = []

    private struct Clause: Sendable {
        let field: String
        let value: String
        let excluded: Bool
        let date: Date?
    }

    public init(_ source: String) {
        do {
            guard source.count <= 4_096 else { throw SyntaxError("Keep searches within 4,096 characters.") }
            let tokens = try Self.tokens(source)
            guard tokens.count <= 128 else { throw SyntaxError("Use no more than 128 search terms.") }
            for token in tokens {
                let excluded = token.hasPrefix("-") && token.count > 1
                let term = excluded ? String(token.dropFirst()) : token
                let pieces = term.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(pieces[0]).lowercased()
                let fields = ["tag", "notebook", "title", "is", "updated-after", "updated-before"]
                let isFilter = pieces.count == 2 && fields.contains(key)
                let field = isFilter ? key : "text"
                let value = isFilter ? String(pieces[1]) : term
                guard !value.isEmpty else { throw SyntaxError("Add a value after \(key):.") }
                if field == "is", !["pinned", "unpinned"].contains(value.lowercased()) {
                    throw SyntaxError("Use is:pinned or is:unpinned.")
                }
                var date: Date?
                if field == "updated-after" || field == "updated-before" {
                    date = Self.date(value)
                    guard date != nil else { throw SyntaxError("Use a real date in YYYY-MM-DD format after \(field):.") }
                }
                clauses.append(Clause(field: field, value: value, excluded: excluded, date: date))
                if field == "text" && !excluded { textTerms.append(value) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func matches(_ note: Note, notebook: String = "") -> Bool {
        guard errorMessage == nil else { return false }
        var text: String?
        return clauses.allSatisfy { clause in
            let matches: Bool
            switch clause.field {
            case "tag":
                matches = note.tags.contains { Self.fold($0) == Self.fold(clause.value) }
            case "notebook":
                let path = Self.fold(notebook), value = Self.fold(clause.value)
                matches = path == value || path.hasPrefix(value + "/")
            case "title":
                matches = note.displayTitle.localizedStandardContains(clause.value)
            case "is":
                matches = clause.value.lowercased() == "pinned" ? note.isPinned : !note.isPinned
            case "updated-after":
                matches = clause.date.map { note.updatedAt >= $0 } ?? false
            case "updated-before":
                matches = clause.date.map { note.updatedAt < $0 } ?? false
            default:
                if text == nil { text = ([note.displayTitle, notebook, note.textContent] + note.tags).joined(separator: "\n") }
                matches = text?.localizedStandardContains(clause.value) == true
            }
            return clause.excluded ? !matches : matches
        }
    }

    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func tokens(_ source: String) throws -> [String] {
        var result: [String] = []
        var token = "", quoted = false, escaped = false, started = false
        for character in source {
            if escaped {
                if character != "\"" && character != "\\" { token.append("\\") }
                token.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                started = true
            } else if character.isWhitespace && !quoted {
                if started {
                    guard !token.isEmpty else { throw SyntaxError("Add some text inside the quoted phrase.") }
                    result.append(token)
                    token = ""
                    started = false
                }
            } else {
                token.append(character)
                started = true
            }
        }
        guard !quoted && !escaped else { throw SyntaxError("Close the double quote in your search.") }
        if started {
            guard !token.isEmpty else { throw SyntaxError("Add some text inside the quoted phrase.") }
            result.append(token)
        }
        return result
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    private struct SyntaxError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
