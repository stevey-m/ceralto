import Foundation

public enum LibraryBackup {
    /// Writes a new portable directory; URLs in its manifest are relative to that directory.
    public static func export(_ library: Library, to destination: URL) throws {
        let manager = FileManager.default
        try library.validate()
        guard !manager.fileExists(atPath: destination.path) else {
            throw JoplinImportError.invalid("Choose a new backup folder. Existing folders are never overwritten.")
        }
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
            guard !destination.standardizedFileURL.path.hasPrefix(resource.root.path + "/") else {
                throw JoplinImportError.invalid("The backup cannot be created inside its own attachments.")
            }
            let path = roots[resource.root] ?? "resources/\(UUID().uuidString)"
            roots[resource.root] = path
            let relative = String(resource.source.path.dropFirst(resource.root.path.count + 1))
            portable.notes[index].importedRootURL = URL(string: path + "/")
            portable.notes[index].importedSourceURL = URL(string: path + "/")?.appendingPathComponent(relative)
        }
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

    public static func imported(from folder: URL, importsDirectory: URL) throws -> JoplinImportResult {
        guard var library = try LibraryStorage(url: folder.appendingPathComponent("library.json")).load() else {
            throw JoplinImportError.invalid("This folder is not a Folio backup.")
        }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let destination = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard !destination.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw JoplinImportError.invalid("Choose a backup outside Folio's import storage.")
        }
        var ids: [UUID: UUID] = [:]
        library.notebooks = library.notebooks.map { notebook in
            let copy = Notebook(name: notebook.name)
            ids[notebook.id] = copy.id
            return copy
        }
        var remapped: [Note] = []
        for note in library.notes {
            guard let notebookID = ids[note.notebookID] else { throw LibraryError.invalidLibrary }
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
                notebookID: notebookID, title: note.title, body: note.body, tags: note.tags,
                isPinned: note.isPinned, deletedAt: note.deletedAt, createdAt: note.createdAt, updatedAt: note.updatedAt,
                importedSourceURL: try relocate(note.importedSourceURL), importedRootURL: try relocate(note.importedRootURL),
                format: note.format, history: note.history
            ))
        }
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        do {
            try copyDirectory(root, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try JoplinImport.discardSnapshot(destination, after: error)
            }
            throw error
        }
        return JoplinImportResult(notebooks: library.notebooks, notes: remapped, snapshotURL: destination)
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
