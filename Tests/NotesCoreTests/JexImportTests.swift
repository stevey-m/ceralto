import Foundation
import NotesCore
import Testing
@testable import Folio

struct JexImportTests {
    private let folder = String(repeating: "a", count: 32)
    private let child = String(repeating: "b", count: 32)
    private let first = String(repeating: "c", count: 32)
    private let second = String(repeating: "d", count: 32)
    private let resource = String(repeating: "e", count: 32)
    private let tag = String(repeating: "f", count: 32)
    private let relation = String(repeating: "1", count: 32)

    @Test func importsNestedNotebooksTagsDatesResourcesAndInternalLinksIndependently() throws {
        try directory { root in
            let archive = root.appendingPathComponent("export.jex")
            try tar(entries()).write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            #expect(result.report.notes == 2)
            #expect(result.report.notebooks == 2)
            #expect(result.report.tags == 1)
            #expect(result.report.resources == 1)
            #expect(result.report.warnings.isEmpty)
            #expect(result.imported.notebooks.map(\.name) == ["Work", "Work/Ideas"])
            let note = try #require(result.imported.notes.first { $0.title == "Café note" })
            let target = try #require(result.imported.notes.first { $0.title == "Another note" })
            #expect(note.tags == ["two words"])
            #expect(note.body.contains("![Photo](../resources/\(resource).png)"))
            #expect(note.body.contains("[Jump](folio-note://\(target.id.uuidString))"))
            #expect(note.body.contains("id: This belongs to the body\n\nLast paragraph"))
            #expect(note.createdAt == ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
            #expect(note.updatedAt == ISO8601DateFormatter().date(from: "2021-02-03T04:05:06Z"))
            let resources = ImportedResources(source: try #require(note.importedSourceURL), root: result.imported.snapshotURL)
            let image = try #require(resources.localURL(for: "../resources/\(resource).png"))
            try FileManager.default.removeItem(at: archive)
            #expect(try Data(contentsOf: image) == Data([0, 1, 2, 255]))
            let html = try PreviewDocument.html(source: note.body, format: .markdown, resources: resources)
            #expect(html.contains("folio-note://\(target.id.uuidString)"))
            #expect(html.contains("folio-resource://local"))
            #expect(FileManager.default.fileExists(atPath: result.imported.snapshotURL.appendingPathComponent("original-joplin/\(first).md").path))
            let saved = try JSONDecoder().decode(JexImportReport.self, from: Data(contentsOf: result.imported.snapshotURL.appendingPathComponent("import-report.json")))
            #expect(saved.notes == result.report.notes)
        }
    }

    @Test func reportsUnconvertedMetadataTodoStatusAndUnknownLinksWithoutHidingThem() throws {
        try directory { root in
            var files = entries()
            let original = try #require(String(data: files[2].1, encoding: .utf8))
            files[2].1 = Data(original.replacingOccurrences(of: "type_: 1", with: "is_todo: 1\ntodo_completed: 0\ntodo_due: 12345\ntype_: 1")
                .replacingOccurrences(of: "Last paragraph", with: "[Unknown](:/22222222222222222222222222222222)").utf8)
            files.append((String(repeating: "3", count: 32) + ".md",
                          record(id: String(repeating: "3", count: 32), type: 13, title: nil, properties: ["body_diff: retained"])))
            let archive = root.appendingPathComponent("todos.jex")
            try tar(files).write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            let todo = try #require(result.imported.notes.first { $0.title == "Café note" })
            #expect(todo.body.hasPrefix("- [ ] To do\n\n"))
            #expect(result.report.warnings.contains { $0.contains("to-do status") })
            #expect(result.report.warnings.contains { $0.contains("unresolved internal link") })
            #expect(result.report.warnings.contains { $0.contains("type 13") })
            #expect(result.report.summary.contains("migration warnings"))
        }
    }

    @Test func rejectsTraversalLinksCorruptionDuplicateNamesAndTruncationBeforeCommit() throws {
        try directory { root in
            let archive = root.appendingPathComponent("unsafe.jex")
            let imports = root.appendingPathComponent("Imports")
            var corrupt = tar(entries())
            corrupt[0] ^= 1
            let invalidArchives: [Data] = [
                tar([("../outside", Data("bad".utf8))]),
                tar([("/absolute", Data())]),
                tar([("resources/../../outside", Data())]),
                tar([("resources\\outside", Data())]),
                tar([("link", Data())], type: 50),
                tar([("hardlink", Data())], type: 49),
                tar([("device", Data())], type: 51),
                tar([("same.md", Data()), ("SAME.md", Data())]),
                corrupt,
                Data(tar(entries()).dropLast(1024)),
                Data(tar(entries()).prefix(600))
            ]
            for bytes in invalidArchives {
                try bytes.write(to: archive)
                #expect(throws: (any Error).self) { try JexImport.prepare(archive: archive, importsDirectory: imports) }
                #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
            }
        }
    }

    @Test func rejectsMissingAttachmentsEncryptedNotesBrokenHierarchyAndRelationships() throws {
        try directory { root in
            let archive = root.appendingPathComponent("bad.jex")
            let imports = root.appendingPathComponent("Imports")
            var encrypted = entries()
            let text = try #require(String(data: encrypted[2].1, encoding: .utf8))
            encrypted[2].1 = Data(text.replacingOccurrences(of: "type_: 1", with: "encryption_applied: 1\ntype_: 1").utf8)
            var locked = entries()
            locked[2].1 = Data(text.replacingOccurrences(of: "type_: 1", with: "is_locked: 1\ntype_: 1").utf8)
            var cycle = entries()
            cycle[0].1 = record(id: folder, type: 2, title: "Work", properties: ["parent_id: \(child)"])
            var missingTag = entries()
            missingTag.removeAll { $0.0 == tag + ".md" }
            for files in [entries().filter { !$0.0.hasPrefix("resources/") }, encrypted, locked, cycle, missingTag] {
                try tar(files).write(to: archive)
                #expect(throws: (any Error).self) { try JexImport.prepare(archive: archive, importsDirectory: imports) }
                #expect(try FileManager.default.contentsOfDirectory(atPath: imports.path).isEmpty)
            }
        }
    }

    @Test func supportsPortablePaxHeadersAndRejectsUnsafeExtendedPaths() throws {
        try directory { root in
            var extended = tar([("PaxHeader", pax("path", first + ".md"))], type: 120)
            extended.removeLast(1024)
            extended.append(tar(entries().map { $0.0 == first + ".md" ? ("placeholder.md", $0.1) : $0 }
                .sorted { $0.0 == "placeholder.md" && $1.0 != "placeholder.md" }))
            let archive = root.appendingPathComponent("extended.jex")
            try extended.write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            #expect(result.imported.notes.count == 2)
            var bad = tar([("PaxHeader", pax("path", "../escaped.md"))], type: 120)
            bad.removeLast(1024)
            bad.append(tar([("placeholder", Data("bad".utf8))]))
            try bad.write(to: archive)
            #expect(throws: (any Error).self) {
                try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Rejected"))
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.md").path))
        }
    }

    @MainActor @Test func commitsWithExistingNotesAndRollsBackOnStorageFailure() throws {
        try directory { root in
            let archive = root.appendingPathComponent("export.jex")
            try tar(entries()).write(to: archive)
            let suite = "DeltosJex-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = LibraryStorage(url: root.appendingPathComponent("Library/library.json"))
            let store = NotesStore(storage: storage, preferences: defaults)
            let original = store.library
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            try store.commitJoplinImport(result.imported)
            #expect(store.library.notes.count == original.notes.count + 2)
            #expect(store.library.notes.contains(original.notes[0]))
            #expect(try storage.load() == store.library)
            let before = store.library
            let failed = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            try FileManager.default.removeItem(at: storage.url)
            try FileManager.default.createDirectory(at: storage.url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.commitJoplinImport(failed.imported) }
            #expect(store.library == before)
            #expect(!FileManager.default.fileExists(atPath: failed.imported.snapshotURL.path))
        }
    }

    @Test func previewOnlyAllowsWellFormedInternalNoteLinks() throws {
        let valid = UUID()
        let source = "[Valid](folio-note://\(valid.uuidString)) [Invalid](folio-note://not-a-note) [Extra](folio-note://\(valid.uuidString)/file)"
        let html = try PreviewDocument.html(source: source, format: .markdown, resources: nil)
        #expect(html.contains("href=\"folio-note://\(valid.uuidString)\""))
        #expect(!html.contains("href=\"folio-note://not-a-note"))
        #expect(!html.contains("\(valid.uuidString)/file"))
    }

    @Test func translatesRealLinksButPreservesCodeAndLiteralResourceIdentifiers() throws {
        try directory { root in
            let body = """
            Café ![Photo](:/\(resource))

            `![Literal](:/\(resource))`

            ```markdown
            [Example](:/\(second))
            ```

                ![Indented](:/\(resource))

            A literal :/\(resource) stays unchanged.

            [Photo][picture]

            [picture]: :/\(resource)
            """
            var files = entries()
            files[2].1 = record(id: first, type: 1, title: "Links", body: body, properties: ["parent_id: \(child)"])
            let archive = root.appendingPathComponent("links.jex")
            try tar(files).write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            let imported = try #require(result.imported.notes.first { $0.title == "Links" })
            #expect(imported.body.contains("Café ![Photo](../resources/\(resource).png)"))
            #expect(imported.body.contains("`![Literal](:/\(resource))`"))
            #expect(imported.body.contains("[Example](:/\(second))"))
            #expect(imported.body.contains("    ![Indented](:/\(resource))"))
            #expect(imported.body.contains("A literal :/\(resource) stays unchanged."))
            #expect(imported.body.contains("[picture]: ../resources/\(resource).png"))
        }
    }

    @Test func acceptsAnArchiveProducedByTheSystemTarWriter() throws {
        try directory { root in
            let source = root.appendingPathComponent("Raw")
            for (name, data) in entries() {
                let target = source.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            }
            let archive = root.appendingPathComponent("system-tar.jex")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            task.arguments = ["--format", "ustar", "-cf", archive.path, "-C", source.path] + entries().map(\.0)
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            #expect(task.terminationStatus == 0)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            #expect(result.report.notes == 2)
            #expect(result.report.resources == 1)
        }
    }

    @Test func preservesHtmlNotesTrashStateAndEmptyDates() throws {
        try directory { root in
            var files = entries()
            let html = "<p>A <b>HTML</b> note <a href=\":/\(second)\">linked</a></p><img src=\":/\(resource)\">"
            files[2].1 = record(id: first, type: 1, title: "HTML", body: html,
                               properties: ["parent_id: \(folder)", "markup_language: 2", "deleted_time: 1700000000000"])
            files[3].1 = Data((String(data: files[3].1, encoding: .utf8) ?? "")
                .replacingOccurrences(of: "user_created_time: 2020-01-02T03:04:05.000Z", with: "user_created_time: ")
                .replacingOccurrences(of: "created_time: 2019-01-01T00:00:00.000Z", with: "created_time: ").utf8)
            let archive = root.appendingPathComponent("html.jex")
            try tar(files).write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            let imported = try #require(result.imported.notes.first { $0.title == "HTML" })
            let other = try #require(result.imported.notes.first { $0.title == "Another note" })
            #expect(imported.contentFormat == .html)
            #expect(imported.deletedAt == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(imported.body.contains("folio-note://\(other.id.uuidString)"))
            #expect(imported.body.contains("src=\"../resources/\(resource).png\""))
            #expect(other.createdAt == Date(timeIntervalSince1970: 0))
        }
    }

    @Test func duplicateNotebookNamesStaySeparateAndAreReported() throws {
        try directory { root in
            var files = entries()
            files[1].1 = record(id: child, type: 2, title: "Work")
            let archive = root.appendingPathComponent("duplicate-names.jex")
            try tar(files).write(to: archive)
            let result = try JexImport.prepare(archive: archive, importsDirectory: root.appendingPathComponent("Imports"))
            #expect(Set(result.imported.notebooks.map(\.name)).count == 2)
            #expect(Set(result.imported.notes.map(\.notebookID)).count == 2)
            #expect(result.report.warnings.contains { $0.contains("duplicate notebook path") })
        }
    }

    private func entries() -> [(String, Data)] {
        [
            (folder + ".md", record(id: folder, type: 2, title: "Work")),
            (child + ".md", record(id: child, type: 2, title: "Ideas", properties: ["parent_id: \(folder)"])),
            (first + ".md", record(id: first, type: 1, title: "Café note",
                                  body: "![Photo](:/\(resource))\n\n[Jump](:/\(second))\n\nid: This belongs to the body\n\nLast paragraph",
                                  properties: ["parent_id: \(child)", "markup_language: 1"])),
            (second + ".md", record(id: second, type: 1, title: "Another note", body: "Other",
                                   properties: ["parent_id: \(folder)"])),
            (resource + ".md", record(id: resource, type: 4, title: "Photo", properties: ["mime: image/png", "file_extension: png"])),
            ("resources/" + resource + ".png", Data([0, 1, 2, 255])),
            (tag + ".md", record(id: tag, type: 5, title: "Two Words")),
            (relation + ".md", record(id: relation, type: 6, title: nil, properties: ["note_id: \(first)", "tag_id: \(tag)"]))
        ]
    }

    private func record(id: String, type: Int, title: String?, body: String = "", properties: [String] = []) -> Data {
        let header = title.map { $0 + "\n\n" + (body.isEmpty ? "" : body + "\n\n") } ?? ""
        return Data((header + (["id: \(id)", "created_time: 2019-01-01T00:00:00.000Z",
                                "updated_time: 2019-01-01T00:00:00.000Z",
                                "user_created_time: 2020-01-02T03:04:05.000Z",
                                "user_updated_time: 2021-02-03T04:05:06.000Z"] + properties +
                               ["type_: \(type)"]).joined(separator: "\n")).utf8)
    }

    private func tar(_ files: [(String, Data)], type: UInt8 = 48) -> Data {
        var result = Data()
        for (path, bytes) in files {
            var header = Data(repeating: 0, count: 512)
            func put(_ text: String, at index: Int) { header.replaceSubrange(index..<index + text.utf8.count, with: text.utf8) }
            put(path, at: 0)
            put("0000644", at: 100)
            put("0000000", at: 108)
            put("0000000", at: 116)
            put(String(format: "%011o", bytes.count), at: 124)
            put("00000000000", at: 136)
            put("        ", at: 148)
            header[156] = type
            put("ustar", at: 257)
            put("00", at: 263)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", checksum) + "\0 ", at: 148)
            result.append(header)
            result.append(bytes)
            result.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    private func pax(_ key: String, _ value: String) -> Data {
        let tail = " \(key)=\(value)\n"
        var length = tail.utf8.count + 1
        while String(length).utf8.count + tail.utf8.count != length {
            length = String(length).utf8.count + tail.utf8.count
        }
        return Data((String(length) + tail).utf8)
    }

    private func directory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove JEX fixture: \(error.localizedDescription)") }
        }
        try body(root)
    }
}
