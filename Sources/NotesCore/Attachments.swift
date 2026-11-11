import Foundation
import UniformTypeIdentifiers
import SwiftSoup

public struct NoteAttachment: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case image = "Images", pdf = "PDFs", file = "Other Files"
    }

    public let noteID: UUID
    public let noteTitle: String
    public let reference: String
    public let name: String
    public let kind: Kind
    public let resources: ImportedResources
    public var id: String { noteID.uuidString + ":" + reference }

    public func resolvedURL() throws -> URL {
        guard let url = resources.localURL(for: reference) else {
            throw NoteWorkflowError("This attachment links outside its note's resource folder.")
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard info.isRegularFile == true else {
            throw NoteWorkflowError("The attachment is missing or is not a regular file.")
        }
        return url
    }
}

public enum Attachments {
    public static func references(in note: Note) throws -> [NoteAttachment] {
        if note.importedRootURL == nil && note.importedSourceURL == nil { return [] }
        guard let root = note.importedRootURL, let source = note.importedSourceURL else {
            throw NoteWorkflowError("The note's attachment folder information is incomplete.")
        }
        let resources = ImportedResources(source: source, root: root)
        let html = note.contentFormat.usesHTML ? note.body : try PreviewDocument.markdownHTML(note.body)
        let document = try SwiftSoup.parse(html)
        var seen: Set<String> = []
        var attachments: [NoteAttachment] = []
        for element in try document.select("img[src],a[href]") {
            let image = element.tagName() == "img"
            let reference = try element.attr(image ? "src" : "href")
            guard !reference.isEmpty, !reference.hasPrefix("#") else { continue }
            if let url = URL(string: reference), url.scheme != nil, !url.isFileURL { continue }
            guard let url = resources.localURL(for: reference) else {
                throw NoteWorkflowError("An attachment in \"\(note.displayTitle)\" links outside its resource folder.")
            }
            guard seen.insert(url.path).inserted else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let kind: NoteAttachment.Kind = type?.conforms(to: .image) == true || image ? .image :
                type?.conforms(to: .pdf) == true ? .pdf : .file
            let label = try (image ? element.attr("alt") : element.text()).trimmingCharacters(in: .whitespacesAndNewlines)
            attachments.append(NoteAttachment(noteID: note.id, noteTitle: note.displayTitle, reference: reference,
                                              name: label.isEmpty ? url.lastPathComponent : String(label.prefix(200)),
                                              kind: kind, resources: resources))
        }
        return attachments
    }

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
