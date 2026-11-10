import Foundation
import UniformTypeIdentifiers

public enum Attachments {
    public struct Imported: Sendable {
        public let fragment: String
        public let resources: ImportedResources
        public let directory: URL
    }

    public static func adding(files: [URL], to original: Note, directory: URL) throws -> Note {
        guard !files.isEmpty else { return original }
        let imported = try importing(files: files, for: original, directory: directory)
        var note = original
        note.importedRootURL = imported.resources.root
        note.importedSourceURL = imported.resources.source
        let addition = imported.fragment
        if note.contentFormat.usesHTML, let end = note.body.range(of: "</body>", options: .caseInsensitive) {
            note.body.insert(contentsOf: "\n\(addition)\n", at: end.lowerBound)
        } else {
            note.body += "\n\n" + addition + "\n"
        }
        note.updatedAt = Date()
        return note
    }

    public static func importing(files: [URL], for original: Note, directory: URL) throws -> Imported {
        guard !files.isEmpty else {
            throw JoplinImportError.invalid("Choose at least one attachment.")
        }
        let manager = FileManager.default
        let batch = UUID().uuidString
        let root = original.importedRootURL ?? directory.appendingPathComponent(original.id.uuidString, isDirectory: true)
        let source = original.importedSourceURL ?? root.appendingPathComponent("note.md")
        let destination = source.deletingLastPathComponent().appendingPathComponent("attachments-\(batch)", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var fragments: [String] = []
        do {
            for (index, file) in files.enumerated() {
                let name = "\(index)-\(file.lastPathComponent)"
                let target = destination.appendingPathComponent(name)
                try manager.copyItem(at: file, to: target)
                let path = "attachments-\(batch)/\(name)"
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "()#?\"<>")
                guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw JoplinImportError.invalid("The attachment filename could not be encoded.")
                }
                let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
                if original.contentFormat.usesHTML {
                    let label = file.lastPathComponent.replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
                    fragments.append(isImage ? "<p><img src=\"\(encoded)\" alt=\"\(label)\"></p>"
                                     : "<p><a href=\"\(encoded)\">\(label)</a></p>")
                } else {
                    let label = file.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    fragments.append("\(isImage ? "!" : "")[\(label)](\(encoded))")
                }
            }
        } catch {
            try JoplinImport.discardSnapshot(destination, after: error)
            throw error
        }
        return Imported(fragment: fragments.joined(separator: "\n\n"),
                        resources: ImportedResources(source: source, root: root), directory: destination)
    }
}
