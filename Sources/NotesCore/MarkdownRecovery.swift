import CryptoKit
import Foundation

public struct MarkdownSession: Codable, Sendable {
    public var version = 1
    public var bookmark: Data
    public var root: URL
    public var selectedPath: String?

    public init(bookmark: Data, root: URL, selectedPath: String?) {
        self.bookmark = bookmark
        self.root = root
        self.selectedPath = selectedPath
    }
}

public struct MarkdownDraft: Codable, Equatable, Identifiable, Sendable {
    public var version = 1
    public let root: URL
    public let path: String
    public let original: MarkdownSource
    public let text: String
    public let updatedAt: Date
    public var id: String { Self.key(root: root, path: path) }

    public init(root: URL, path: String, original: MarkdownSource, text: String, updatedAt: Date = Date()) {
        self.root = root
        self.path = path
        self.original = original
        self.text = text
        self.updatedAt = updatedAt
    }

    static func key(root: URL, path: String) -> String {
        SHA256.hash(data: Data((root.absoluteString + "\n" + path).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Local recovery state never writes metadata or drafts into the user's Markdown folder.
public struct MarkdownRecovery: Sendable {
    public let directory: URL
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var draftsURL: URL { directory.appendingPathComponent("Drafts", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    public func session() throws -> MarkdownSession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        let value = try JSONDecoder().decode(MarkdownSession.self, from: Data(contentsOf: sessionURL))
        guard value.version == 1, value.root.isFileURL else {
            throw NoteWorkflowError("The saved Markdown session is invalid or uses an unsupported version.")
        }
        return value
    }

    public func saveSession(_ session: MarkdownSession) throws {
        // A corrupt saved session is preserved until the user explicitly forgets it.
        _ = try self.session()
        try prepare(directory)
        try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
    }

    public func forgetSession() throws {
        if FileManager.default.fileExists(atPath: sessionURL.path) { try FileManager.default.removeItem(at: sessionURL) }
    }

    public func drafts(for root: URL) throws -> [MarkdownDraft] {
        guard FileManager.default.fileExists(atPath: draftsURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: draftsURL, includingPropertiesForKeys: nil)
        var result: [MarkdownDraft] = []
        for file in files where file.pathExtension == "json" {
            let draft = try readDraft(file)
            if draft.root == root { result.append(draft) }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveDraft(_ draft: MarkdownDraft) throws {
        try validate(draft)
        let file = draftsURL.appendingPathComponent(draft.id + ".json")
        if FileManager.default.fileExists(atPath: file.path) { _ = try readDraft(file) }
        try prepare(draftsURL)
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
    }

    public func removeDraft(root: URL, path: String) throws {
        let file = draftsURL.appendingPathComponent(MarkdownDraft.key(root: root, path: path) + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try readDraft(file)
            try FileManager.default.removeItem(at: file)
        }
    }

    private func readDraft(_ file: URL) throws -> MarkdownDraft {
        let draft = try JSONDecoder().decode(MarkdownDraft.self, from: Data(contentsOf: file))
        try validate(draft)
        guard file.deletingPathExtension().lastPathComponent == draft.id else {
            throw NoteWorkflowError("A Markdown recovery draft has an invalid identity. Its file has been preserved.")
        }
        return draft
    }

    private func validate(_ draft: MarkdownDraft) throws {
        let parts = draft.path.split(separator: "/", omittingEmptySubsequences: false)
        guard draft.version == 1, draft.root.isFileURL,
              !parts.isEmpty, parts.allSatisfy({
                  !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") &&
                  $0.rangeOfCharacter(from: .controlCharacters) == nil
              }), ["md", "markdown"].contains((draft.path as NSString).pathExtension.lowercased()),
              draft.original.digest.count == 64,
              draft.original.digest.allSatisfy({ $0.isHexDigit }) else {
            throw NoteWorkflowError("A Markdown recovery draft is invalid or from an unsupported version. Its file has been preserved.")
        }
    }

    private func prepare(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
}
