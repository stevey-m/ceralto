import Foundation
import NotesCore
import Testing

struct LibraryTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func firstRunHasNoLibrary() throws {
        try withDirectory { directory in
            let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
            let loaded = try storage.load()
            #expect(loaded == nil)
        }
    }

    @Test func savesAndReloadsAllFields() throws {
        try withDirectory { directory in
            let storage = LibraryStorage(url: directory.appendingPathComponent("nested/library.json"))
            let notebook = Notebook(name: "Ideas")
            let note = Note(
                notebookID: notebook.id, title: "Cafe \u{2615}", body: "# Hello\n\nA thought.",
                tags: ["swift", "personal"], isPinned: true, deletedAt: Date(timeIntervalSince1970: 123)
            )
            let library = Library(notebooks: [notebook], notes: [note])
            try storage.save(library)
            let loaded = try storage.load()
            #expect(loaded == library)
        }
    }

    @Test func corruptLibraryIsNotReplacedByLoad() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("library.json")
            let original = Data("not json".utf8)
            try original.write(to: url)
            #expect(throws: (any Error).self) { try LibraryStorage(url: url).load() }
            let preserved = try Data(contentsOf: url)
            #expect(preserved == original)
        }
    }

    @Test func rejectsInvalidRelationshipsWithoutOverwriting() throws {
        try withDirectory { directory in
            let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
            let original = Library.starter()
            try storage.save(original)
            var invalid = original
            invalid.notes[0].notebookID = UUID()
            #expect(throws: (any Error).self) { try storage.save(invalid) }
            let preserved = try storage.load()
            #expect(preserved == original)
            invalid = original
            invalid.notes.append(invalid.notes[0])
            #expect(throws: (any Error).self) { try storage.save(invalid) }
        }
    }

    @Test func rejectsUnsupportedVersions() throws {
        var library = Library.starter()
        library.version = 2
        #expect(throws: (any Error).self) { try library.validate() }
    }

    @Test func normalizesAndDeduplicatesTags() {
        #expect(Note.normalizedTags([" Swift ", "", "SWIFT", "Work", " "]) == ["swift", "work"])
    }

    @Test func searchesAcrossTitleBodyAndTagsWithAllTerms() {
        let note = Note(
            notebookID: UUID(), title: "Caf\u{00e9} ideas", body: "Build a Mac app", tags: ["swift"]
        )
        #expect(note.matches("CAFE swift"))
        #expect(note.matches("Mac ideas"))
        #expect(note.matches("  "))
        #expect(!note.matches("swift missing"))
    }

    @Test func handlesBlankTitlesAndWordCounts() {
        let note = Note(notebookID: UUID(), title: " \n ", body: "one  two\nthree\tfour")
        #expect(note.displayTitle == "Untitled note")
        #expect(note.wordCount == 4)
        #expect(!note.excerpt.contains("\n"))
    }

    @Test(arguments: [NoteFormat.markdown, .formatted, .html])
    func previewsShowReadableMixedContentInsteadOfMarkupAndResourcePaths(format: NoteFormat) {
        let source = """
        <div><table role="none"><tr><td>
        <p>First &amp; second&nbsp;thought</p><p><br></p>
        <img src="../../_resources/private-image.png" alt="Useful diagram">
        </td></tr></table></div>

        """
        let body = source + "\n" + (format == .html ? "<h3>Next topic</h3>" : "### Next topic")
        let note = Note(notebookID: UUID(), body: body, format: format)
        #expect(note.excerpt.contains("First & second"))
        #expect(note.excerpt.contains("Useful diagram"))
        #expect(note.excerpt.contains("Next topic"))
        for syntax in ["<p>", "<br>", "<div>", "role=", "_resources", "private-image.png", "&nbsp;", "###"] {
            #expect(!note.excerpt.contains(syntax))
        }
        #expect(note.body == body)
        #expect(note.matches("Useful diagram"))
    }

    @Test func previewsKeepVisibleCodeTableCellsAndLinkLabels() {
        let note = Note(notebookID: UUID(), body: """
        [Guide](https://example.test/hidden-path)

        | Product | Amount |
        | --- | --- |
        | Pencil | 12 |

        ```html
        <p>Literal code</p>
        ```
        """)
        #expect(note.textContent.contains("Guide"))
        #expect(!note.textContent.contains("hidden-path"))
        #expect(note.textContent.contains("Pencil"))
        #expect(note.textContent.contains("12"))
        #expect(note.textContent.contains("<p>Literal code</p>"))
        #expect(!note.textContent.contains("```"))
        #expect(note.matches("Pencil"))
        let html = Note(notebookID: UUID(), body: """
        <script>invisible-script</script><style>invisible-style</style>
        <p>Visible words</p>
        """, format: .html)
        #expect(html.excerpt == "Visible words")
        #expect(html.wordCount == 2)
    }

    @Test func markdownRoundTripPreservesContent() throws {
        try withDirectory { directory in
            let note = Note(notebookID: UUID(), title: "Meeting / plans", body: "# Title\n\n- [ ] Task\n")
            let filename = MarkdownFile.filename(for: note)
            #expect(filename == "Meeting - plans.md")
            let url = directory.appendingPathComponent(filename)
            try MarkdownFile.export(note, to: url)
            let imported = try MarkdownFile.imported(from: url, notebookID: note.notebookID)
            #expect(imported.body == note.body)
            #expect(imported.title == "Meeting - plans")
            #expect(imported.notebookID == note.notebookID)
        }
    }

    @Test func invalidUTF8ImportFails() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("invalid.md")
            try Data([0xff, 0xfe, 0xff]).write(to: url)
            #expect(throws: (any Error).self) {
                try MarkdownFile.imported(from: url, notebookID: UUID())
            }
        }
    }
}
