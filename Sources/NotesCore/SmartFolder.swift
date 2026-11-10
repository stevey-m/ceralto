import Foundation

public struct SmartFolderError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SmartFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SmartFolderStorage: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    private struct Document: Codable {
        var version = 1
        let folders: [SmartFolder]
    }

    public func load() throws -> [SmartFolder] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else {
            throw SmartFolderError("Saved smart folders use an unsupported version: \(document.version).")
        }
        try Self.validate(document.folders)
        return document.folders
    }

    public func save(_ folders: [SmartFolder]) throws {
        try Self.validate(folders)
        let data = try JSONEncoder().encode(Document(folders: folders))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func validate(_ folders: [SmartFolder]) throws {
        guard Set(folders.map(\.id)).count == folders.count else {
            throw SmartFolderError("The saved smart folders contain duplicate identifiers.")
        }
        var names: Set<String> = []
        for folder in folders {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                            locale: Locale(identifier: "en_US_POSIX"))).inserted else {
                throw SmartFolderError("Give each smart folder a unique name of 1-100 characters.")
            }
            guard !folder.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SmartFolderError("Add a search rule for the smart folder.")
            }
            if let error = NoteQuery(folder.query).errorMessage { throw SmartFolderError(error) }
        }
    }
}
