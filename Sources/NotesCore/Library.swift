import Foundation
import SwiftSoup

public enum NoteFormat: String, Codable, Sendable {
    case markdown, html, formatted

    public var usesHTML: Bool { self == .html }
}

public struct NoteRevision: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let savedAt: Date
    public let title: String
    public let body: String
    public let format: NoteFormat?

    public init(note: Note, savedAt: Date = Date()) {
        id = UUID()
        self.savedAt = savedAt
        title = note.title
        body = note.body
        format = note.format
    }
}

public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var notebookID: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    public var isPinned: Bool
    public var deletedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var importedSourceURL: URL?
    public var importedRootURL: URL?
    public var format: NoteFormat?
    public var history: [NoteRevision]?

    public var contentFormat: NoteFormat { format ?? .markdown }

    public init(
        id: UUID = UUID(), notebookID: UUID, title: String = "", body: String = "",
        tags: [String] = [], isPinned: Bool = false, deletedAt: Date? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(),
        importedSourceURL: URL? = nil, importedRootURL: URL? = nil,
        format: NoteFormat? = nil, history: [NoteRevision]? = nil
    ) {
        self.id = id
        self.notebookID = notebookID
        self.title = title
        self.body = body
        self.tags = Self.normalizedTags(tags)
        self.isPinned = isPinned
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.importedSourceURL = importedSourceURL
        self.importedRootURL = importedRootURL
        self.format = format
        self.history = history
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }

    public var textContent: String {
        guard contentFormat != .markdown else { return body }
        do {
            if contentFormat == .formatted {
                return try FormattedPage(markdown: body).blocks.map {
                    $0.runs.map(\.text).joined()
                }.joined(separator: "\n")
            }
            let document = try SwiftSoup.parse(body)
            try document.select("script,style").remove()
            return try document.text()
        } catch {
            NSLog("Could not extract note text: %@", error.localizedDescription)
            return body
        }
    }

    public var excerpt: String {
        textContent.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    public var wordCount: Int {
        textContent.split(whereSeparator: \.isWhitespace).count
    }

    public mutating func recordRevision(of previous: Note, now: Date = Date(), force: Bool = false) {
        guard title != previous.title || body != previous.body || format != previous.format else { return }
        var revisions = previous.history ?? []
        if force || revisions.last.map({ now.timeIntervalSince($0.savedAt) >= 300 }) ?? true {
            revisions.append(NoteRevision(note: previous, savedAt: now))
        }
        history = Array(revisions.suffix(20))
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted()
    }

    public func matches(_ query: String, notebook: String = "") -> Bool {
        NoteQuery(query).matches(self, notebook: notebook)
    }
}

public struct Library: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var notebooks: [Notebook]
    public var notes: [Note]
    public var folderSync: FolderSyncState?

    public init(notebooks: [Notebook], notes: [Note] = []) {
        self.notebooks = notebooks
        self.notes = notes
    }

    public static func starter() -> Library {
        let notebook = Notebook(name: "Personal")
        let welcome = Note(
            notebookID: notebook.id, title: "A little space for your thoughts",
            body: """
            # Welcome to Folio

            Your notes, on your Mac. A quiet place to think, write, and collect ideas.

            ## Make yourself at home

            - Create a notebook for each part of your life.
            - Write in Markdown, then switch to Preview or Split.
            - Add comma-separated tags to connect your ideas.
            - Pin the notes you want to keep close.

            ## Keep your words

            Notes save automatically to this Mac. Import and export Markdown files \
            whenever you like. Deleted notes stay in Trash until you permanently delete them.

            > Start with a thought. See where it takes you.

            **Tip:** Press Command-N to start a new note.
            """,
            tags: ["getting-started"], isPinned: true
        )
        return Library(notebooks: [notebook], notes: [welcome])
    }

    public func validate() throws {
        guard version == 1 else { throw LibraryError.unsupportedVersion(version) }
        let notebookIDs = Set(notebooks.map(\.id))
        guard !notebooks.isEmpty,
              notebookIDs.count == notebooks.count,
              Set(notes.map(\.id)).count == notes.count,
              notebooks.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              notes.allSatisfy({ notebookIDs.contains($0.notebookID) }) else {
            throw LibraryError.invalidLibrary
        }
    }
}

public enum LibraryError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidLibrary

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This library uses an unsupported format (version \(version))."
        case .invalidLibrary:
            "The library contains invalid or duplicate records. The existing file has not been replaced."
        }
    }
}

public struct LibraryStorage: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var applicationDefault: LibraryStorage {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Folio", isDirectory: true)
        return LibraryStorage(url: directory.appendingPathComponent("library.json"))
    }

    public func load() throws -> Library? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
        try library.validate()
        return library
    }

    public func save(_ library: Library) throws {
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}

public enum MarkdownFile {
    public static func imported(from url: URL, notebookID: UUID) throws -> Note {
        let body = try String(contentsOf: url, encoding: .utf8)
        return Note(
            notebookID: notebookID,
            title: url.deletingPathExtension().lastPathComponent,
            body: body
        )
    }

    public static func filename(for note: Note) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let title = note.displayTitle.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(title.prefix(120)) + ".md"
    }

    public static func export(_ note: Note, to url: URL) throws {
        try note.body.write(to: url, atomically: true, encoding: .utf8)
    }
}

public enum ImportedDocument {
    public static let extensions: Set<String> = ["md", "markdown", "txt", "html", "htm"]

    public static func parse(_ source: String, filename: String, extension suffix: String,
                             notebookID: UUID) throws -> Note {
        if ["html", "htm"].contains(suffix.lowercased()) {
            let document = try SwiftSoup.parse(source)
            let title = try document.title().trimmingCharacters(in: .whitespacesAndNewlines)
            return Note(notebookID: notebookID, title: title.isEmpty ? filename : title,
                        body: source, format: .html)
        }
        return try JoplinImport.parse(source, filename: filename, notebookID: notebookID)
    }
}
