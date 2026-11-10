import Foundation
import Yams

public struct JoplinImportResult: Sendable {
    public let notebooks: [Notebook]
    public let notes: [Note]
    public let snapshotURL: URL
}

public enum JoplinImportError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

public enum JoplinImport {
    /// Validates all notes before copying a self-contained snapshot of the export.
    public static func prepare(folder: URL, importsDirectory: URL, includeHTML: Bool = false) throws -> JoplinImportResult {
        let manager = FileManager.default
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw JoplinImportError.invalid("Select a Joplin Markdown + Front Matter export folder.")
        }
        let destination = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        guard !destination.path.hasPrefix(root.path + "/") else {
            throw JoplinImportError.invalid("The export folder cannot contain Deltos's import storage.")
        }
        var files: [URL] = []
        var enumerationError: (any Error)?
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw JoplinImportError.invalid("The export folder could not be read.")
        }
        for case let file as URL in enumerator {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true else {
                throw JoplinImportError.invalid("Symbolic links are not supported in exports: \(file.lastPathComponent)")
            }
            if info.isRegularFile == true { files.append(file.standardizedFileURL) }
        }
        if let enumerationError { throw enumerationError }
        files.sort { $0.path < $1.path }
        var notebooksByPath: [String: Notebook] = [:]
        var notes: [Note] = []
        let extensions: Set<String> = includeHTML ? ImportedDocument.extensions : ["md", "markdown"]
        for file in files where extensions.contains(file.pathExtension.lowercased()) {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            // Joplin stores resources alongside notes, not as notebook contents.
            if components.dropLast().contains(where: {
                ["_resources", "resources", "assets"].contains($0.lowercased()) || $0.lowercased().hasSuffix("_files")
            }) { continue }
            let path = components.dropLast().joined(separator: "/")
            let notebook: Notebook
            if let existing = notebooksByPath[path] {
                notebook = existing
            } else {
                notebook = Notebook(name: path.isEmpty ? root.lastPathComponent : path)
                notebooksByPath[path] = notebook
            }
            do {
                let source = try String(contentsOf: file, encoding: .utf8)
                var note = try ImportedDocument.parse(
                    source, filename: file.deletingPathExtension().lastPathComponent,
                    extension: file.pathExtension, notebookID: notebook.id
                )
                note.importedRootURL = destination
                note.importedSourceURL = destination.appendingPathComponent(relative)
                notes.append(note)
            } catch {
                throw JoplinImportError.invalid("\(relative): \(error.localizedDescription)")
            }
        }
        guard !notes.isEmpty else {
            throw JoplinImportError.invalid("No Markdown notes were found. Export from Joplin using Markdown + Front Matter, then select that folder. RAW directories and JEX archives are not supported.")
        }
        try manager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let target = destination.appendingPathComponent(relative)
                // Recheck resolved paths before copying in case a source is a link.
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else {
                    throw JoplinImportError.invalid("A file points outside the selected export folder: \(relative)")
                }
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: target)
            }
        } catch {
            try discardSnapshot(destination, after: error)
            throw error
        }
        return JoplinImportResult(
            notebooks: notebooksByPath.keys.sorted().compactMap { notebooksByPath[$0] },
            notes: notes, snapshotURL: destination
        )
    }

    public static func discardSnapshot(_ url: URL, after error: any Error) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let cleanupError {
            throw JoplinImportError.invalid(
                "\(error.localizedDescription)\nCould not remove the incomplete import at \(url.path): \(cleanupError.localizedDescription)"
            )
        }
    }

    public static func parse(_ source: String, filename: String, notebookID: UUID) throws -> Note {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{feff}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return Note(notebookID: notebookID, title: filename, body: source)
        }
        guard let closing = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            throw JoplinImportError.invalid("The YAML front matter has no closing --- delimiter.")
        }
        let yaml = lines[1..<closing].joined(separator: "\n")
        guard let node = try Yams.compose(yaml: yaml), let mapping = node.mapping else {
            throw JoplinImportError.invalid("The front matter must be a YAML mapping.")
        }
        var seen = Set<String>()
        for pair in mapping {
            guard let key = pair.key.string, seen.insert(key).inserted else {
                throw JoplinImportError.invalid("The front matter contains duplicate or invalid keys.")
            }
        }
        func string(_ key: String) throws -> String? {
            guard let value = node[key] else { return nil }
            guard let text = value.string else {
                throw JoplinImportError.invalid("The '\(key)' field must be text.")
            }
            return text
        }
        func date(_ key: String) throws -> Date? {
            guard let text = try string(key) else { return nil }
            let iso = ISO8601DateFormatter()
            let canonical = text.replacingOccurrences(of: " ", with: "T")
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = iso.date(from: canonical) { return value }
            iso.formatOptions = [.withInternetDateTime]
            if let value = iso.date(from: canonical) { return value }
            for format in ["yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mmXXXXX",
                           "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = format
                formatter.isLenient = false
                if let value = formatter.date(from: text) { return value }
            }
            throw JoplinImportError.invalid("The '\(key)' date is invalid: \(text)")
        }
        var tags: [String] = []
        if let value = node["tags"] {
            guard let sequence = value.sequence else {
                throw JoplinImportError.invalid("The 'tags' field must be a YAML list.")
            }
            tags = try sequence.map {
                guard let tag = $0.string else {
                    throw JoplinImportError.invalid("Each tag must be text.")
                }
                return tag
            }
        }
        var bodyStart = closing + 1
        if bodyStart < lines.count, lines[bodyStart].isEmpty { bodyStart += 1 }
        return Note(
            notebookID: notebookID, title: try string("title") ?? filename,
            body: lines[bodyStart...].joined(separator: "\n"), tags: tags,
            createdAt: try date("created") ?? Date(), updatedAt: try date("updated") ?? Date()
        )
    }
}
