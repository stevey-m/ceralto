import CryptoKit
import Foundation

public struct MarkdownEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct MarkdownSource: Codable, Equatable, Sendable {
    public let text: String
    public let digest: String
}

public struct LiveMarkdownFolder: Sendable {
    public let root: URL
    public static let maximumNoteBytes = 16 * 1024 * 1024

    public init(root: URL) throws {
        guard root.isFileURL else { throw NoteWorkflowError("Choose a local, downloaded folder.") }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw NoteWorkflowError("The Markdown folder is missing or is not a directory.")
        }
        self.root = canonical
    }

    public func entries() throws -> [MarkdownEntry] {
        _ = try LiveMarkdownFolder(root: root)
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in failure = error; return false }) else {
            throw NoteWorkflowError("Cannot read the Markdown folder.")
        }
        var result: [MarkdownEntry] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isDirectory == true || (values.isRegularFile == true && Self.isMarkdown(file)) else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { throw NoteWorkflowError("A folder entry escaped its library.") }
            result.append(MarkdownEntry(path: String(path.dropFirst(root.path.count + 1)), isDirectory: values.isDirectory == true))
        }
        if let failure { throw failure }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func read(_ path: String) throws -> MarkdownSource {
        let file = try url(for: path)
        guard Self.isMarkdown(file) else { throw NoteWorkflowError("Choose a .md or .markdown file.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumNoteBytes else {
            throw NoteWorkflowError("Only regular UTF-8 Markdown files up to 16 MB can be edited.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumNoteBytes + 1) ?? Data()
        guard data.count <= Self.maximumNoteBytes, let text = String(data: data, encoding: .utf8) else {
            throw NoteWorkflowError("This note is too large or is not UTF-8 Markdown. Its file was not changed.")
        }
        return MarkdownSource(text: text, digest: Self.digest(data))
    }

    public func save(_ text: String, at path: String, expectedDigest: String) throws -> MarkdownSource {
        guard text.utf8.count <= Self.maximumNoteBytes else { throw NoteWorkflowError("Notes must be no larger than 16 MB.") }
        return try coordinateWrite(try url(for: path)) { file in
            let current = try read(path)
            guard current.digest == expectedDigest else {
                throw NoteWorkflowError("This file changed outside Deltos. Your draft is preserved. Reload the disk version or save your draft as a new copy.")
            }
            try Data(text.utf8).write(to: file, options: .atomic)
            return try read(path)
        }
    }

    public func createNote(at path: String, text: String = "") throws {
        let file = try url(for: path)
        guard Self.isMarkdown(file), text.utf8.count <= Self.maximumNoteBytes else {
            throw NoteWorkflowError("Use a .md or .markdown filename and no more than 16 MB of UTF-8 text.")
        }
        try coordinateWrite(file.deletingLastPathComponent()) { _ in
            _ = try url(for: path)
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        }
    }

    public func createDirectory(at path: String) throws {
        let folder = try url(for: path)
        try coordinateWrite(folder.deletingLastPathComponent()) { _ in
            _ = try url(for: path)
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw NoteWorkflowError("That destination already exists.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
    }

    public func move(_ source: String, to destination: String) throws {
        let from = try url(for: source)
        let to = try url(for: destination)
        guard source != destination, !destination.hasPrefix(source + "/") else {
            throw NoteWorkflowError("Choose a different destination outside the folder being moved.")
        }
        let directory = try from.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard directory || (Self.isMarkdown(from) && Self.isMarkdown(to)) else {
            throw NoteWorkflowError("Markdown notes must retain their .md or .markdown extension.")
        }
        try coordinateWrite(root) { _ in
            _ = try url(for: source)
            _ = try url(for: destination)
            guard !FileManager.default.fileExists(atPath: to.path) else { throw NoteWorkflowError("The destination exists. Files and folders are never merged or overwritten.") }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    public func url(for path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { throw NoteWorkflowError("Use a relative path with visible folder names, without . or .. segments.") }
        let currentRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard currentRoot == root,
              try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
            throw NoteWorkflowError("The Markdown folder moved or is no longer available. Reopen it before editing.")
        }
        var file = root
        for part in parts {
            file.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: file.path) {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw NoteWorkflowError("Symbolic links cannot be edited or traversed in a live library.")
                }
            }
        }
        guard file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw NoteWorkflowError("That path is outside the Markdown library.")
        }
        return file
    }

    private func coordinateWrite<Value>(_ url: URL, operation: (URL) throws -> Value) throws -> Value {
        var failure: NSError?
        var result: Result<Value, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &failure) { location in
            result = Result { try operation(location) }
        }
        if let failure { throw failure }
        guard let result else { throw NoteWorkflowError("The filesystem operation could not be coordinated.") }
        return try result.get()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
