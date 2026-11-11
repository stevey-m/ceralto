import Foundation

public enum LibraryBackup {
    /// Writes a new portable directory; URLs in its manifest are relative to that directory.
    public static func export(_ library: Library, to destination: URL) throws {
        let manager = FileManager.default
        try library.validate()
        guard !manager.fileExists(atPath: destination.path) else {
            throw JoplinImportError.invalid("Choose a new backup folder. Existing folders are never overwritten.")
        }
        let (portable, roots) = try portableSnapshot(library, avoiding: destination)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try manager.createDirectory(at: destination.appendingPathComponent("resources"), withIntermediateDirectories: true)
            for (root, path) in roots {
                try copyDirectory(root, to: destination.appendingPathComponent(path))
            }
            try LibraryStorage(url: destination.appendingPathComponent("library.json")).save(portable)
        } catch {
            try JoplinImport.discardSnapshot(destination, after: error)
            throw error
        }
    }

    static func portableSnapshot(_ library: Library, avoiding destination: URL? = nil) throws -> (Library, [URL: String]) {
        try library.validate()
        var portable = library
        portable.folderSync = nil
        var roots: [URL: String] = [:]
        for index in portable.notes.indices {
            guard let root = portable.notes[index].importedRootURL,
                  let source = portable.notes[index].importedSourceURL else { continue }
            let resource = ImportedResources(source: source, root: root)
            guard resource.isContained(source) else {
                throw JoplinImportError.invalid("A note has an invalid attachment path.")
            }
            if let destination, destination.standardizedFileURL.path.hasPrefix(resource.root.path + "/") {
                throw JoplinImportError.invalid("The backup cannot be created inside its own attachments.")
            }
            let path = roots[resource.root] ?? "resources/\(UUID().uuidString)"
            roots[resource.root] = path
            let relative = String(resource.source.path.dropFirst(resource.root.path.count + 1))
            portable.notes[index].importedRootURL = URL(string: path + "/")
            portable.notes[index].importedSourceURL = URL(string: path + "/")?.appendingPathComponent(relative)
        }
        return (portable, roots)
    }

    public static func imported(from folder: URL, importsDirectory: URL) throws -> JoplinImportResult {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let destination = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard !destination.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw JoplinImportError.invalid("Choose a backup outside Deltos's import storage.")
        }
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let hasReceipt = FileManager.default.fileExists(atPath: root.appendingPathComponent("backup-receipt.json").path)
        do {
            try copyDirectory(root, to: destination)
            if hasReceipt || FileManager.default.fileExists(atPath: destination.appendingPathComponent("backup-receipt.json").path) {
                try ManagedBackups.verifyPortableCopy(destination)
            }
            return try importedSnapshot(at: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try JoplinImport.discardSnapshot(destination, after: error)
            }
            throw error
        }
    }

    static func importedSnapshot(at destination: URL) throws -> JoplinImportResult {
        guard var library = try LibraryStorage(url: destination.appendingPathComponent("library.json")).load() else {
            throw JoplinImportError.invalid("This folder is not a Deltos or Folio backup.")
        }
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        var ids: [UUID: UUID] = [:]
        library.notebooks = library.notebooks.map { notebook in
            let copy = Notebook(name: notebook.name)
            ids[notebook.id] = copy.id
            return copy
        }
        var remapped: [Note] = []
        let noteIDs = Dictionary(uniqueKeysWithValues: library.notes.map { ($0.id, UUID()) })
        for note in library.notes {
            guard let notebookID = ids[note.notebookID], let noteID = noteIDs[note.id] else { throw LibraryError.invalidLibrary }
            func relocate(_ url: URL?) throws -> URL? {
                guard let url else { return nil }
                let path = url.relativeString
                guard url.scheme == nil, !path.hasPrefix("/"),
                      let decoded = path.removingPercentEncoding else {
                    throw JoplinImportError.invalid("The backup contains nonportable resource paths.")
                }
                let candidate = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
                guard candidate.path.hasPrefix(root.path + "/") else {
                    throw JoplinImportError.invalid("The backup contains a path outside its folder.")
                }
                return destination.appendingPathComponent(String(candidate.path.dropFirst(root.path.count + 1)))
            }
            remapped.append(Note(
                id: noteID,
                notebookID: notebookID, title: note.title,
                body: try remappingLinks(note.body, format: note.contentFormat, ids: noteIDs), tags: note.tags,
                isPinned: note.isPinned, deletedAt: note.deletedAt, createdAt: note.createdAt, updatedAt: note.updatedAt,
                importedSourceURL: try relocate(note.importedSourceURL), importedRootURL: try relocate(note.importedRootURL),
                format: note.format, history: try note.history?.map {
                    NoteRevision(copying: $0, body: try remappingLinks($0.body, format: $0.format ?? .markdown, ids: noteIDs))
                }
            ))
        }
        return JoplinImportResult(notebooks: library.notebooks, notes: remapped, snapshotURL: destination)
    }

    private static func remappingLinks(_ source: String, format: NoteFormat, ids: [UUID: UUID]) throws -> String {
        let references = try NSRegularExpression(
            pattern: #"(?im)(?:\]\([ \t]*<?|\b(?:href)[ \t]*=[ \t]*["']|^ {0,3}\[[^\]\n]+\]:[ \t]*<?)(folio-note://([a-fA-F0-9-]{36}))(?![a-fA-F0-9-])"#)
        let code = format.usesHTML ? [] : try JexImport.codeRanges(in: source)
        var result = source
        for match in references.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard !code.contains(where: { NSIntersectionRange($0, match.range(at: 1)).length > 0 }),
                  let idRange = Range(match.range(at: 2), in: source),
                  let id = UUID(uuidString: String(source[idRange])), let replacement = ids[id],
                  let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: "folio-note://" + replacement.uuidString)
        }
        return result
    }

    private static func copyDirectory(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                  options: []) else {
            throw JoplinImportError.invalid("The resource folder cannot be read.")
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw JoplinImportError.invalid("Backups cannot contain symbolic links.")
            }
        }
        try manager.copyItem(at: source, to: destination)
    }
}
