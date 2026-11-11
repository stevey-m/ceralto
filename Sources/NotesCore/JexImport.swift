import Foundation
import cmark_gfm

public struct JexImportReport: Codable, Sendable {
    public let notes: Int
    public let notebooks: Int
    public let tags: Int
    public let resources: Int
    public let warnings: [String]

    public var summary: String {
        var text = "Imported \(notes) notes, \(notebooks) notebooks, \(tags) tags and \(resources) attachments. Existing notes were preserved. Original Joplin records and a migration report are retained with the import."
        if !warnings.isEmpty { text += "\n\nReview \(warnings.count) migration warnings in import-report.json:\n" + warnings.prefix(8).joined(separator: "\n") }
        return text
    }
}

public struct JexImportResult: Sendable {
    public let imported: JoplinImportResult
    public let report: JexImportReport
}

/// Reads Joplin's uncompressed TAR export without invoking an archive extractor.
public enum JexImport {
    public static func prepare(archive: URL, importsDirectory: URL) throws -> JexImportResult {
        let manager = FileManager.default
        let info = try archive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 536_870_912 else {
            throw invalid("Choose an uncompressed JEX archive no larger than 512 MiB.")
        }
        let data = try Data(contentsOf: archive)
        guard data.count <= 536_870_912 else { throw invalid("The archive exceeds 512 MiB.") }
        let destination = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let raw = destination.appendingPathComponent("original-joplin", isDirectory: true)
            let files = try JexArchive.unpack(data, into: raw)
            return try convert(files: files, raw: raw, destination: destination)
        } catch {
            try JoplinImport.discardSnapshot(destination, after: error)
            throw error
        }
    }

    private struct Item {
        let id: String
        let type: Int
        let title: String
        let body: String
        let properties: [String: String]

        init(_ text: String, filename: String) throws {
            var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let separator = lines.lastIndex(of: "") ?? -1
            var properties: [String: String] = [:]
            for line in lines.suffix(from: separator + 1) {
                guard let colon = line.firstIndex(of: ":") else { throw invalid("\(filename): malformed metadata.") }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, properties[key] == nil else { throw invalid("\(filename): duplicate metadata field.") }
                properties[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard let id = properties["id"], validID(id),
                  filename == id + ".md", let type = properties["type_"].flatMap(Int.init) else {
                throw invalid("\(filename): invalid item identifier or type.")
            }
            guard ["", "0"].contains(properties["encryption_applied", default: "0"]),
                  ["", "0"].contains(properties["encryption_blob_encrypted", default: "0"]),
                  ["", "0"].contains(properties["is_locked", default: "0"]),
                  properties["encryption_cipher_text", default: ""].isEmpty else {
                throw invalid("\(filename): decrypt/unlock notes in Joplin before exporting. No notes were imported.")
            }
            self.id = id
            self.type = type
            self.properties = properties
            let content = Array(lines.prefix(max(0, separator)))
            if [1, 2, 4, 5].contains(type) {
                title = content.first ?? ""
                guard content.count < 2 || content[1].isEmpty else {
                    throw invalid("\(filename): malformed title/body separator.")
                }
                body = type == 1 ? content.dropFirst(2).joined(separator: "\n") : ""
            } else {
                title = ""
                body = ""
            }
        }

        func date(_ field: String, fallback: String) throws -> Date {
            guard properties[field] != nil || properties[fallback] != nil else {
                throw invalid("\(id): missing \(field).")
            }
            let value = properties[field].flatMap { $0.isEmpty ? nil : $0 } ?? properties[fallback] ?? ""
            if value.isEmpty || value == "0" { return Date(timeIntervalSince1970: 0) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw invalid("\(id): invalid or missing \(field).") }
            return date
        }
    }

    private static func convert(files: [String], raw: URL, destination: URL) throws -> JexImportResult {
        let manager = FileManager.default
        var items: [String: Item] = [:]
        var warnings: [String] = []
        for file in files.sorted() where !file.contains("/") {
            guard file.hasSuffix(".md") else {
                warnings.append("Retained unrecognised archive file: \(file).")
                continue
            }
            let url = raw.appendingPathComponent(file)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 33_554_432 else { throw invalid("\(file): item exceeds 32 MiB.") }
            let item = try Item(String(contentsOf: url, encoding: .utf8), filename: file)
            guard items.updateValue(item, forKey: item.id) == nil else { throw invalid("Duplicate Joplin item: \(item.id).") }
        }
        guard items.values.contains(where: { $0.type == 1 }) else { throw invalid("The JEX archive contains no readable notes.") }
        var paths: [String: String] = [:]
        var occupiedPaths = Set<String>()
        func path(_ id: String, ancestors: Set<String> = []) throws -> String {
            if let cached = paths[id] { return cached }
            guard ancestors.count < 64, !ancestors.contains(id), let item = items[id], item.type == 2 else {
                throw invalid("Notebook hierarchy is missing, cyclic or deeper than 64 levels: \(id).")
            }
            let name = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw invalid("Notebook \(id) has no name.") }
            let safeName = name.replacingOccurrences(of: "/", with: "\u{ff0f}")
            if safeName != name { warnings.append("Notebook \(id): replaced a slash in its name to preserve hierarchy.") }
            let parent = item.properties["parent_id", default: ""]
            let prefix = parent.isEmpty ? "" : try path(parent, ancestors: ancestors.union([id])) + "/"
            var result = prefix + safeName
            if occupiedPaths.contains(result.lowercased()) {
                result += " [\(id)]"
                warnings.append("Notebook \(id): added its identifier to distinguish a duplicate notebook path.")
            }
            guard occupiedPaths.insert(result.lowercased()).inserted else {
                throw invalid("Notebook names could not be disambiguated: \(id).")
            }
            paths[id] = result
            return result
        }
        var notebooks: [String: Notebook] = [:]
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.type == 2 {
            notebooks[item.id] = Notebook(name: try path(item.id))
        }
        let noteIDs = Dictionary(uniqueKeysWithValues: items.values.filter { $0.type == 1 }.map { ($0.id, UUID()) })
        let tagItems = items.filter { $0.value.type == 5 }
        var tagsByNote: [String: [String]] = [:]
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.type == 6 {
            guard let note = item.properties["note_id"], noteIDs[note] != nil,
                  let tagID = item.properties["tag_id"], let tag = tagItems[tagID], !tag.title.isEmpty else {
                throw invalid("Tag relationship \(item.id) references a missing note or tag.")
            }
            tagsByNote[note, default: []].append(tag.title)
        }
        var resourcePaths: [String: String] = [:]
        let resourceFiles = Dictionary(grouping: files.filter { $0.hasPrefix("resources/") }) {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        }
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.type == 4 {
            let candidates = resourceFiles[item.id] ?? []
            guard candidates.count == 1, let file = candidates.first else {
                throw invalid("Attachment \(item.id) is missing or ambiguous. Re-download it in Joplin and export again.")
            }
            let source = raw.appendingPathComponent(file)
            let ext = source.pathExtension
            guard ext.count <= 20, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw invalid("Attachment \(item.id) has an unsafe file extension.")
            }
            let relative = "resources/" + item.id + (ext.isEmpty ? "" : "." + ext)
            let target = destination.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: target)
            resourcePaths[item.id] = "../" + relative
        }
        let references = try NSRegularExpression(
            pattern: #"(?im)(?:\]\([ \t]*<?|\b(?:href|src)[ \t]*=[ \t]*["']|^ {0,3}\[[^\]\n]+\]:[ \t]*<?)(:/([a-fA-F0-9]{32}))(?![a-fA-F0-9])"#)
        var notes: [Note] = []
        var fallbackNotebook: Notebook?
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.type == 1 {
            let parent = item.properties["parent_id", default: ""]
            let notebook: Notebook
            if let existing = notebooks[parent] { notebook = existing }
            else if parent.isEmpty {
                if fallbackNotebook == nil { fallbackNotebook = Notebook(name: "Joplin Import") }
                guard let fallbackNotebook else { throw invalid("Could not create an import notebook.") }
                notebook = fallbackNotebook
            } else { throw invalid("Note \(item.id) references a missing notebook.") }
            guard let id = noteIDs[item.id] else { throw invalid("Note identifier is missing.") }
            let markup = item.properties["markup_language", default: "1"]
            guard ["1", "2"].contains(markup) else { throw invalid("Note \(item.id) has an unsupported markup language.") }
            var body = item.body
            let code = markup == "1" ? try codeRanges(in: body) : []
            let matches = references.matches(in: body, range: NSRange(body.startIndex..., in: body))
            for match in matches.reversed() {
                if code.contains(where: { NSIntersectionRange($0, match.range(at: 1)).length > 0 }) { continue }
                guard let range = Range(match.range(at: 1), in: body), let idRange = Range(match.range(at: 2), in: body) else {
                    throw invalid("Could not translate an internal Joplin link.")
                }
                let target = String(body[idRange])
                if let path = resourcePaths[target] { body.replaceSubrange(range, with: path) }
                else if let noteID = noteIDs[target] { body.replaceSubrange(range, with: "folio-note://" + noteID.uuidString) }
                else { warnings.append("Note \(item.id): unresolved internal link to \(target), retained unchanged.") }
            }
            if item.properties["is_todo"] == "1" {
                let completion = item.properties["todo_completed"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
                guard let completed = Int64(completion), completed >= 0 else {
                    throw invalid("Note \(item.id) has an invalid completion time.")
                }
                let done = completed > 0
                if markup == "1" { body = "- [\(done ? "x" : " ")] " + (done ? "Completed" : "To do") + "\n\n" + body }
                warnings.append("Note \(item.id): Joplin to-do status converted to a checklist for Markdown; original due date and metadata retained in the source record.")
            }
            let deletion = item.properties["deleted_time"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
            guard let deletedTime = Int64(deletion), deletedTime >= 0 else {
                throw invalid("Note \(item.id) has an invalid deletion time.")
            }
            let note = Note(id: id, notebookID: notebook.id, title: item.title, body: body,
                            tags: tagsByNote[item.id] ?? [],
                            deletedAt: deletedTime > 0 ? Date(timeIntervalSince1970: Double(deletedTime) / 1000) : nil,
                            createdAt: try item.date("user_created_time", fallback: "created_time"),
                            updatedAt: try item.date("user_updated_time", fallback: "updated_time"),
                            importedSourceURL: destination.appendingPathComponent("notes/" + id.uuidString + (markup == "2" ? ".html" : ".md")),
                            importedRootURL: destination, format: markup == "2" ? .html : .markdown)
            notes.append(note)
            let source = try requireSource(note)
            try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: source, atomically: true, encoding: .utf8)
        }
        for type in Set(items.values.map(\.type)).subtracting([1, 2, 4, 5, 6]).sorted() {
            warnings.append("Joplin item type \(type) retained in original-joplin, not converted (including any revision or application settings).")
        }
        let knownResources = Set(resourcePaths.keys)
        for file in files where file.hasPrefix("resources/") {
            if !knownResources.contains(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent) {
                warnings.append("Unreferenced attachment retained in original-joplin: \(file).")
            }
        }
        var importedNotebooks = notebooks.values.sorted { $0.name < $1.name }
        if let fallbackNotebook { importedNotebooks.append(fallbackNotebook) }
        let report = JexImportReport(notes: notes.count, notebooks: importedNotebooks.count,
                                     tags: tagItems.count, resources: resourcePaths.count, warnings: warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination.appendingPathComponent("import-report.json"), options: .atomic)
        return JexImportResult(imported: JoplinImportResult(notebooks: importedNotebooks, notes: notes, snapshotURL: destination),
                               report: report)
    }

    private static func requireSource(_ note: Note) throws -> URL {
        guard let source = note.importedSourceURL else { throw invalid("Imported source path is missing.") }
        return source
    }

    private static func codeRanges(in source: String) throws -> [NSRange] {
        guard let parser = cmark_parser_new(0) else { throw invalid("Could not inspect Markdown links.") }
        defer { cmark_parser_free(parser) }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { throw invalid("Could not inspect Markdown links.") }
        defer { cmark_node_free(document) }
        var lineStarts = [0]
        for (index, byte) in source.utf8.enumerated() where byte == 10 { lineStarts.append(index + 1) }
        var result: [NSRange] = []
        func visit(_ node: UnsafeMutablePointer<cmark_node>) throws {
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_CODE || type == CMARK_NODE_CODE_BLOCK {
                let firstLine = Int(cmark_node_get_start_line(node)) - 1
                let lastLine = Int(cmark_node_get_end_line(node)) - 1
                guard lineStarts.indices.contains(firstLine), lineStarts.indices.contains(lastLine) else {
                    throw invalid("Could not locate a Markdown code span.")
                }
                let start = lineStarts[firstLine] + max(0, Int(cmark_node_get_start_column(node)) - 1)
                let end = lineStarts[lastLine] + Int(cmark_node_get_end_column(node))
                let bytes = source.utf8
                guard start <= end, end <= bytes.count,
                      let lower = String.Index(bytes.index(bytes.startIndex, offsetBy: start), within: source),
                      let upper = String.Index(bytes.index(bytes.startIndex, offsetBy: end), within: source) else {
                    throw invalid("Could not locate a Markdown code span.")
                }
                result.append(NSRange(lower..<upper, in: source))
                return
            }
            var child = cmark_node_first_child(node)
            while let current = child {
                try visit(current)
                child = cmark_node_next(current)
            }
        }
        try visit(document)
        return result
    }

    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    private static func invalid(_ reason: String) -> JoplinImportError { .invalid(reason) }
}

private enum JexArchive {
    static func unpack(_ data: Data, into root: URL) throws -> [String] {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var offset = 0
        var files: [String] = []
        var seen = Set<String>()
        var extended: [String: String] = [:]
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard extended.isEmpty, data.count - offset >= 1024,
                      data[offset...].allSatisfy({ $0 == 0 }) else { throw invalid("Invalid TAR end marker.") }
                return files
            }
            guard files.count < 100_000 else { throw invalid("The archive contains too many files.") }
            let checksum = try octal(header, 148..<156)
            let actual = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard checksum == actual else { throw invalid("A TAR header checksum is invalid.") }
            let size = try octal(header, 124..<136)
            guard size <= 134_217_728, size <= data.count - offset - 512 else { throw invalid("An archive entry is too large or truncated.") }
            let end = offset + 512 + size
            let paddedEnd = offset + 512 + ((size + 511) / 512) * 512
            guard paddedEnd <= data.count else { throw invalid("An archive entry is truncated.") }
            let bytes = data.subdata(in: offset + 512..<end)
            offset = paddedEnd
            let kind = header[156]
            if kind == 120 {
                guard extended.isEmpty, size <= 1_048_576 else { throw invalid("Unsupported extended TAR header.") }
                extended = try pax(bytes)
                continue
            }
            guard kind == 0 || kind == 48 || kind == 53 else {
                throw invalid("JEX archives must not contain links, devices or unsupported TAR records.")
            }
            let name = try text(header, 0..<100)
            let prefix = try text(header, 345..<500)
            var path = extended["path"] ?? (prefix.isEmpty ? name : prefix + "/" + name)
            if let paxSize = extended["size"], Int(paxSize) != size { throw invalid("Conflicting TAR entry sizes.") }
            extended.removeAll()
            while path.hasPrefix("./") { path.removeFirst(2) }
            if kind == 53, path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.contains("\0"), !path.contains(":"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(path.lowercased()).inserted else { throw invalid("Unsafe or duplicate archive path.") }
            let target = root.appendingPathComponent(path)
            if kind == 53 {
                guard size == 0 else { throw invalid("A TAR directory has unexpected contents.") }
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                guard components.count == 1 || (components.count == 2 && components.first == "resources") else {
                    throw invalid("Unexpected folder layout. Export a JEX archive directly from Joplin.")
                }
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .withoutOverwriting)
                files.append(path)
            }
        }
        throw invalid("The JEX archive is missing its TAR end marker.")
    }

    private static func text(_ data: Data, _ range: Range<Int>) throws -> String {
        let bytes = data.subdata(in: range).prefix { $0 != 0 }
        guard let value = String(data: Data(bytes), encoding: .utf8) else { throw invalid("Invalid UTF-8 archive header.") }
        return value
    }

    private static func octal(_ data: Data, _ range: Range<Int>) throws -> Int {
        let value = try text(data, range).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...55).contains($0) }),
              let number = Int(value, radix: 8) else { throw invalid("Invalid TAR numeric field.") }
        return number
    }

    private static func pax(_ data: Data) throws -> [String: String] {
        var offset = 0
        var result: [String: String] = [:]
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32),
                  let lengthString = String(data: data[offset..<space], encoding: .ascii),
                  let length = Int(lengthString), length > space - offset + 2, length <= data.count - offset,
                  data[offset + length - 1] == 10,
                  let value = String(data: data[space + 1..<offset + length - 1], encoding: .utf8),
                  let equal = value.firstIndex(of: "=") else { throw invalid("Malformed extended TAR metadata.") }
            let key = String(value[..<equal])
            guard result[key] == nil else { throw invalid("Duplicate extended TAR metadata.") }
            result[key] = String(value[value.index(after: equal)...])
            offset += length
        }
        return result
    }

    private static func invalid(_ reason: String) -> JoplinImportError { .invalid(reason) }
}
