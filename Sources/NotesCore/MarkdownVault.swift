import Foundation
import SwiftSoup
import Yams

public enum MarkdownVault {
    /// Exports ordinary files without changing or moving the working library.
    public static func export(_ library: Library, to destination: URL) throws {
        try library.validate()
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw JoplinImportError.invalid("Choose a new export folder. Existing folders are never overwritten.")
        }
        let names = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            for note in library.notes {
                let notebook = names[note.notebookID] ?? "Notes"
                let collection = note.deletedAt == nil ? "Notebooks" : "Trash"
                let folder = destination.appendingPathComponent(collection)
                    .appendingPathComponent(safeName(notebook) + "-" + note.notebookID.uuidString)
                    .appendingPathComponent(safeName(note.displayTitle) + "-" + note.id.uuidString)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                var documentFolder = folder
                var body = note.body
                if let source = note.importedSourceURL, let root = note.importedRootURL {
                    let resources = ImportedResources(source: source, root: root)
                    guard resources.isContained(source) else {
                        throw JoplinImportError.invalid("A note has an invalid resource location.")
                    }
                    guard !destination.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(resources.root.path + "/") else {
                        throw JoplinImportError.invalid("The export cannot be placed inside its own attachments.")
                    }
                    let sourcePath = String(resources.source.path.dropFirst(resources.root.path.count + 1))
                    documentFolder = folder.appendingPathComponent(sourcePath).deletingLastPathComponent()
                    let html = note.contentFormat.usesHTML ? body : try PreviewDocument.markdownHTML(body)
                    let parsed = try SwiftSoup.parse(html)
                    for element in try parsed.select("img[src],a[href]") {
                        let reference = try element.attr(element.tagName() == "img" ? "src" : "href")
                        guard !reference.isEmpty, !reference.hasPrefix("#") else { continue }
                        if let url = URL(string: reference), url.scheme != nil, !url.isFileURL { continue }
                        guard let local = resources.localURL(for: reference) else {
                            throw JoplinImportError.invalid("A note links outside its resource folder: \(reference)")
                        }
                        let info = try local.resourceValues(forKeys: [.isRegularFileKey])
                        guard info.isRegularFile == true else {
                            throw JoplinImportError.invalid("An attachment is missing: \(reference)")
                        }
                        let relative = String(local.path.dropFirst(resources.root.path.count + 1))
                        let target = folder.appendingPathComponent(relative)
                        if !manager.fileExists(atPath: target.path) {
                            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try manager.copyItem(at: local, to: target)
                        }
                        if URL(string: reference)?.isFileURL == true {
                            // Absolute links are not portable. A relative path from the note's original
                            // directory preserves its relationship to the copied resource tree.
                            let base = resources.source.deletingLastPathComponent().pathComponents
                            let parts = local.pathComponents
                            let common = zip(base, parts).prefix { $0 == $1 }.count
                            let path = Array(repeating: "..", count: base.count - common) + Array(parts.dropFirst(common))
                            guard let portable = path.joined(separator: "/").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                                throw JoplinImportError.invalid("An attachment path could not be encoded for export.")
                            }
                            body = body.replacingOccurrences(of: reference, with: portable)
                        }
                    }
                }
                try manager.createDirectory(at: documentFolder, withIntermediateDirectories: true)
                let suffix = note.contentFormat.usesHTML ? "html" : "md"
                let file = documentFolder.appendingPathComponent(safeName(note.displayTitle) + "." + suffix)
                guard !manager.fileExists(atPath: file.path) else {
                    throw JoplinImportError.invalid("An attachment has the same filename as its note. Rename the note before exporting: \(note.displayTitle)")
                }
                let metadata: [String: Any] = [
                    "title": note.displayTitle, "id": note.id.uuidString, "notebook": notebook,
                    "created": note.createdAt.ISO8601Format(), "updated": note.updatedAt.ISO8601Format(),
                    "tags": note.tags, "pinned": note.isPinned
                ]
                if !note.contentFormat.usesHTML {
                    let yaml = try Yams.dump(object: metadata)
                    body = "---\n" + yaml + "---\n\n" + body
                } else {
                    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: documentFolder.appendingPathComponent("folio-metadata.json"), options: .atomic)
                }
                try body.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            try JoplinImport.discardSnapshot(destination, after: error)
            throw error
        }
    }

    private static func safeName(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let result = text.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return result.isEmpty ? "Untitled" : String(result.prefix(90))
    }
}
