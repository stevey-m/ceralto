import Foundation
import NotesCore
import Testing

struct StructuredSearchTests {
    @Test func phrasesExclusionsAndPlainSearchShareOneMatcher() {
        let note = Note(notebookID: UUID(), title: "Caf\u{e9} release plan",
                        body: "Write the next chapter. https://example.test/guide", tags: ["Review", "work"])
        #expect(note.matches(#""cafe release" chapter -draft"#))
        #expect(!note.matches(#""release cafe""#))
        #expect(!note.matches(#"chapter -"next chapter""#))
        #expect(note.matches("https://example.test/guide"))
        #expect(note.matches("Work/Ideas", notebook: "Work/Ideas"))
        #expect(NoteQuery("   \n").matches(note))
        #expect(NoteQuery("-draft").matches(note))
    }

    @Test func fieldFiltersAreExactWhereDocumentedAndCombineWithAnd() {
        let note = Note(notebookID: UUID(), title: "Release plan", body: "Not archived",
                        tags: ["review", "Caf\u{e9}"], isPinned: true)
        let search = NoteQuery(#"NOTEBOOK:"work/ideas" TAG:CAFÉ title:"Release plan" is:PINNED -tag:archive"#)
        #expect(search.errorMessage == nil)
        #expect(search.matches(note, notebook: "Work/Ideas/Next"))
        #expect(!search.matches(note, notebook: "Work/Ideas-old"))
        #expect(!note.matches("tag:rev"))
        #expect(!note.matches("tag:work"))
        #expect(!note.matches("is:unpinned"))
        #expect(note.matches("-is:unpinned"))
        #expect(!note.matches("tag:review tag:missing"))
        #expect(note.matches("title:plan"))
        #expect(!note.matches("title:archived"))
    }

    @Test func quotingRoundTripsSpacesQuotesAndBackslashes() {
        let name = #"Work/A "quoted" path\folder"#
        let note = Note(notebookID: UUID())
        let query = NoteQuery("notebook:" + NoteQuery.quoted(name))
        #expect(query.errorMessage == nil)
        #expect(query.matches(note, notebook: name))
        #expect(!query.matches(note, notebook: "Work/Other"))
    }

    @Test func dateBoundsUseExactUtcMidnightAndRealCalendarDates() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z"))
        let note = Note(notebookID: UUID(), updatedAt: date)
        #expect(note.matches("updated-after:2026-03-01"))
        #expect(!note.matches("updated-before:2026-03-01"))
        #expect(note.matches("updated-after:2026-02-28 updated-before:2026-03-02"))
        #expect(!note.matches("updated-after:2026-03-02"))
        #expect(note.matches("-updated-before:2026-03-01"))
        #expect(NoteQuery("updated-after:2024-02-29").errorMessage == nil)
        for invalid in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-3-1", "tomorrow", "2026-03-01T00:00:00Z"] {
            #expect(NoteQuery("updated-before:" + invalid).errorMessage != nil)
        }
    }

    @Test func invalidRecognizedSyntaxReportsAnErrorInsteadOfBroadeningResults() {
        let note = Note(notebookID: UUID(), title: "Any note")
        for source in [#"title:"unfinished"#, "tag:", "notebook:", "title:", "is:done", "-is:",
                       #"title:"""#, #""""#, #""" any"#, String(repeating: "a", count: 4_097),
                       Array(repeating: "a", count: 129).joined(separator: " ")] {
            let query = NoteQuery(source)
            #expect(query.errorMessage != nil, "Invalid source: \(source.prefix(80))")
            #expect(!query.matches(note))
        }
        #expect(NoteQuery("unknown:literal").errorMessage == nil)
        #expect(note.matches("any -title:Other"))
    }

    @Test func finderFiltersBeforeRankingKeepsStableLimitsAndExcludesTrash() {
        let notebook = Notebook(name: "Work/Ideas")
        let date = Date(timeIntervalSince1970: 1_000)
        let title = Note(notebookID: notebook.id, title: "Plan", tags: ["review"], updatedAt: date)
        let body = Note(notebookID: notebook.id, title: "Draft", body: "A plan", tags: ["review"], updatedAt: date)
        let excluded = Note(notebookID: notebook.id, title: "Plan", tags: ["archive"], isPinned: true)
        let trash = Note(notebookID: notebook.id, title: "Plan", tags: ["review"], deletedAt: Date())
        let library = Library(notebooks: [notebook], notes: [body, excluded, trash, title])
        #expect(NoteSearch.find("plan tag:review", in: library).map(\.id) == [title.id, body.id])
        #expect(NoteSearch.find("notebook:Work -tag:archive", in: library).count == 2)
        #expect(NoteSearch.find("is:pinned", in: library).map(\.id) == [excluded.id])
        #expect(NoteSearch.find("tag:", in: library).isEmpty)
        #expect(NoteSearch.find("plan", in: library, limit: 1).count == 1)
        #expect(NoteSearch.find("", in: library, limit: 0).isEmpty)
        #expect(NoteSearch.find("", in: library, limit: -1).isEmpty)
        let ties = NoteSearch.find("tag:review", in: library).map(\.id)
        #expect(ties == [title.id, body.id].sorted { $0.uuidString < $1.uuidString })
    }
}
