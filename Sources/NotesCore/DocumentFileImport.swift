import Foundation
import SwiftSoup

public enum DocumentFileImport {
    public static func prepare(files: [URL], notebookID: UUID, importsDirectory: URL) throws -> JoplinImportResult {
        guard !files.isEmpty else { throw JoplinImportError.invalid("Select at least one Markdown or HTML file.") }
        let manager = FileManager.default
        let snapshot = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var copies: [URL: URL] = [:]
        var notes: [Note] = []
        for (index, input) in files.enumerated() {
            let file = input.standardizedFileURL.resolvingSymlinksInPath()
            guard ImportedDocument.extensions.contains(file.pathExtension.lowercased()) else {
                throw JoplinImportError.invalid("Unsupported document: \(file.lastPathComponent)")
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            var note = try ImportedDocument.parse(source, filename: file.deletingPathExtension().lastPathComponent,
                                                 extension: file.pathExtension, notebookID: notebookID)
            let parent = file.deletingLastPathComponent()
            let targetRoot = snapshot.appendingPathComponent(String(index), isDirectory: true)
            note.importedRootURL = targetRoot
            let targetSource = targetRoot.appendingPathComponent(file.lastPathComponent)
            note.importedSourceURL = targetSource
            copies[targetSource] = file
            let html = note.contentFormat == .html ? source : try PreviewDocument.markdownHTML(note.body)
            let document = try SwiftSoup.parse(html)
            let resources = ImportedResources(source: file, root: parent)
            for element in try document.select("img[src],a[href]") {
                let reference = try element.attr(element.tagName() == "img" ? "src" : "href")
                guard !reference.isEmpty, !reference.hasPrefix("#") else { continue }
                if let url = URL(string: reference), url.scheme != nil, !url.isFileURL { continue }
                guard let local = resources.localURL(for: reference) else {
                    throw JoplinImportError.invalid(
                        "\(file.lastPathComponent) links outside its folder (\(reference)). Import the containing Markdown/HTML folder instead so shared resources are included."
                    )
                }
                let info = try local.resourceValues(forKeys: [.isRegularFileKey])
                guard info.isRegularFile == true else {
                    throw JoplinImportError.invalid("A linked resource is missing or is not a file: \(reference)")
                }
                let relative = String(local.path.dropFirst(parent.path.count + 1))
                copies[targetRoot.appendingPathComponent(relative)] = local
            }
            notes.append(note)
        }
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        do {
            for (target, source) in copies {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: target)
            }
        } catch {
            try JoplinImport.discardSnapshot(snapshot, after: error)
            throw error
        }
        return JoplinImportResult(notebooks: [], notes: notes, snapshotURL: snapshot)
    }
}
