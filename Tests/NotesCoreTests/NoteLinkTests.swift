import Foundation
import NotesCore
import Testing

struct NoteLinkTests {
    @Test func wikiLinksAndAliasesResolveWithoutRewritingSourceOrCode() throws {
        let notebook = Notebook(name: "Personal")
        let destination = Note(notebookID: notebook.id, title: "Coffee")
        let source = Note(notebookID: notebook.id, body: "Read [[Coffee|my guide]] and `[[Coffee]]`.\n\n```\n[[Coffee]]\n```")
        let library = Library(notebooks: [notebook], notes: [source, destination])
        let html = try PreviewDocument.html(source: source.body, format: .markdown, resources: nil,
                                            noteLinks: NoteLinks.targets(in: library))
        #expect(html.contains("href=\"folio-note://\(destination.id.uuidString)\""))
        #expect(html.contains(">my guide</a>"))
        #expect(html.contains("<code>[[Coffee]]</code>"))
        let backlinks = try NoteLinks.backlinks(to: destination, in: library)
        #expect(backlinks.map(\.id) == [source.id])
        #expect(source.body.contains("[[Coffee|my guide]]"))
    }

    @Test func duplicateTitlesRequireQualifiedNamesAndTrashIsExcluded() throws {
        let first = Notebook(name: "Personal")
        let second = Notebook(name: "Work")
        let a = Note(notebookID: first.id, title: "Ideas")
        let b = Note(notebookID: second.id, title: "Ideas")
        let deleted = Note(notebookID: first.id, title: "Gone", deletedAt: Date())
        let library = Library(notebooks: [first, second], notes: [a, b, deleted])
        let targets = NoteLinks.targets(in: library)
        #expect(targets["ideas"] == nil)
        #expect(targets["personal/ideas"] == a.id)
        #expect(targets["work/ideas"] == b.id)
        #expect(targets["gone"] == nil)
    }

    @Test func codeOnlyMentionsDoNotCreateBacklinks() throws {
        let notebook = Notebook(name: "Notes")
        let target = Note(notebookID: notebook.id, title: "Target")
        let code = Note(notebookID: notebook.id, body: "`[[Target]]`\n\n```\n[[Target]]\n```")
        let backlinks = try NoteLinks.backlinks(to: target, in: Library(notebooks: [notebook], notes: [target, code]))
        #expect(backlinks.isEmpty)
    }
}
