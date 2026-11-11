import Foundation
import NotesCore
import Testing

struct FormattedPageTests {
    @Test func selectedSizesRoundTripWithStylesTablesAndCode() throws {
        let source = """
        <p>Before <span style="font-size:18pt"><strong><em><u>selected</u></em></strong></span> after</p>
        <table><thead><tr><th>Name</th></tr></thead><tbody><tr><td><span style="font-size:24px">A | B</span></td></tr></tbody></table>
        <pre>code <span style="font-size:20px">larger</span> text</pre>
        """
        let page = try FormattedPage(html: source)
        let selected = try #require(page.blocks[0].runs.first { $0.text == "selected" })
        #expect(selected.fontSize == 24)
        #expect(selected.bold && selected.italic && selected.underline)
        #expect(page.blocks[0].runs.first?.fontSize == nil)
        #expect(try FormattedPage(html: page.html()) == page)
        #expect(try FormattedPage(markdown: page.markdown()) == page)
        #expect(page.markdown().contains("font-size:24.0px"))
        #expect(page.markdown().contains("&#124;"))
    }

    @Test(arguments: ["0px", "-1px", "513px", "nanpx", "infinitypx", "1em", "calc(20px)", "20px!important"])
    func unsupportedFontSizesAreRejectedWithoutFlattening(css: String) {
        #expect(throws: (any Error).self) {
            try FormattedPage(html: "<p><span style=\"font-size:\(css)\">Preserve me</span></p>")
        }
    }

    @Test func previewKeepsOnlyValidatedFontSizeCSS() throws {
        let html = """
        <p><span style="font-size:24px;position:fixed;background:url(https://example.com/tracker)">Selected</span></p>
        <span style="font-size:999999px;color:red">Untrusted</span>
        """
        let safe = try PreviewDocument.sanitizedBody(html, resources: nil)
        #expect(safe.contains("font-size:24.0px"))
        #expect(!safe.contains("position:"))
        #expect(!safe.contains("url("))
        #expect(!safe.contains("example.com"))
        #expect(!safe.contains("999999"))
        #expect(!safe.contains("color:"))
    }

    @Test func portableMarkdownRetainsWritingSemantics() throws {
        let source = """
        # A heading

        A **bold** idea, *italic* words and [a link](https://example.com).

        - First item

        > Keep this thought.

        ![Original photo](assets/photo.jpg)
        """
        let page = try FormattedPage(markdown: source)
        let markdown = page.markdown()
        let restored = try FormattedPage(markdown: markdown)
        #expect(restored.blocks == page.blocks)
        #expect(markdown.contains("**bold**"))
        #expect(markdown.contains("assets/photo.jpg"))
        #expect(!markdown.contains("<strong>"))
    }

    @Test func styledWhitespaceDoesNotBreakMarkdown() throws {
        var first = FormattedRun(text: "hello ")
        first.bold = true
        var second = FormattedRun(text: "world ")
        second.bold = true
        let page = FormattedPage(blocks: [FormattedBlock(runs: [first, second, FormattedRun(text: "again")])])
        let markdown = page.markdown()
        #expect(markdown == "**hello world** again")
        let restored = try FormattedPage(markdown: markdown)
        #expect(restored.blocks[0].runs[0].bold)
        #expect(restored.blocks[0].runs.map(\.text).joined() == "hello world again")
    }

    @Test func typedSyntaxStaysLiteralInTheFormattedEditor() throws {
        let literal = "# not a heading\n- not a list\n1. not numbered\n**literal** [brackets] <script> & text"
        let page = FormattedPage(blocks: [FormattedBlock(runs: [FormattedRun(text: literal)])])
        let restored = try FormattedPage(markdown: page.markdown())
        #expect(restored.blocks.count == 1)
        #expect(restored.blocks[0].style == .paragraph)
        #expect(restored.blocks[0].runs.map(\.text).joined() == literal,
                "Restored: \(restored.blocks[0].runs.map(\.text).joined()); Markdown: \(page.markdown())")
    }

    @Test func codeContainingBackticksRoundTrips() throws {
        let code = "let fence = \"```\"\nprint(fence)"
        let page = FormattedPage(blocks: [FormattedBlock(style: .code, runs: [FormattedRun(text: code)])])
        let restored = try FormattedPage(markdown: page.markdown())
        #expect(restored.blocks[0].style == .code)
        #expect(restored.blocks[0].runs.map(\.text).joined() == code)
    }

    @Test func activeHTMLIsNeverInterpretedAsNativeContent() throws {
        let page = try FormattedPage(html: "<p>Safe <a href=\"javascript:alert(1)\">text</a></p><script>bad()</script>")
        #expect(page.blocks.flatMap(\.runs).map(\.text).joined() == "Safe text")
        #expect(!page.html().contains("javascript:"))
        #expect(!page.html().contains("bad()"))
    }

    @Test func emptyParagraphsDoNotAccumulateLineBreaks() throws {
        let page = try FormattedPage(markdown: "One\n\n<p><br></p>\n\nTwo")
        let restored = try FormattedPage(markdown: page.markdown())
        #expect(page == restored)
        #expect(page.blocks.count == 3)
        #expect(page.blocks[1].runs.isEmpty)
    }

    @Test func orderedNestedChecklistAndGFMTableKeepTheirSemanticStructure() throws {
        let source = """
        3. Parent
           1. **Nested**
              - Deep item
        4. Last

        - [x] Done
        - [ ] Later

        | Name | Details |
        | --- | --- |
        | **A \\| B** | [Open](folio-note://123e4567-e89b-12d3-a456-426614174000) |
        """
        let page = try FormattedPage(markdown: source)
        #expect(page.blocks.map(\.style) == [.ordered, .ordered, .bullet, .ordered, .checklist, .checklist, .table])
        #expect(page.blocks.map(\.listDepth) == [0, 1, 2, 0, 0, 0, 0])
        #expect(page.blocks[0].orderedNumber == 3)
        #expect(page.blocks[3].orderedNumber == 4)
        #expect(page.blocks[4].checked)
        #expect(!page.blocks[5].checked)
        #expect(page.blocks[6].tableRows.count == 2)
        #expect(page.blocks[6].tableRows[1][0].runs.map(\.text).joined() == "A | B")
        #expect(page.blocks[6].tableRows[1][1].runs.contains {
            $0.link == "folio-note://123e4567-e89b-12d3-a456-426614174000"
        })

        let restored = try FormattedPage(markdown: page.markdown())
        #expect(restored == page)
        let fromHTML = try FormattedPage(html: page.html())
        #expect(fromHTML == page)
        #expect(page.markdown().contains("| **A \\| B** |"))
    }

    @Test func looseTaskListsInlineFormattingAndNestedOrderedStartsRoundTrip() throws {
        let loose = try FormattedPage(markdown: "- [x] **Done** item\n\n- [ ] Open `code`\n")
        #expect(loose.blocks.map(\.style) == [.checklist, .checklist])
        #expect(loose.blocks.map(\.checked) == [true, false])
        #expect(loose.blocks[0].runs.contains { $0.bold && $0.text == "Done" })
        #expect(loose.blocks[1].runs.contains { $0.code && $0.text == "code" })
        let nested = FormattedPage(blocks: [
            FormattedBlock(style: .ordered, runs: [FormattedRun(text: "First")], orderedNumber: 1),
            FormattedBlock(style: .ordered, runs: [FormattedRun(text: "Second")], listDepth: 1, orderedNumber: 2)
        ])
        let restored = try FormattedPage(markdown: nested.markdown())
        #expect(restored.blocks.map(\.listDepth) == [0, 1])
        #expect(restored.blocks.map(\.orderedNumber) == [1, 2])
        #expect(restored.blocks.map { $0.runs.map(\.text).joined() } == ["First", "Second"])
        #expect(throws: (any Error).self) { try FormattedPage(markdown: "- Item\n\n  > quoted inside item\n") }
    }

    @Test func internalNoteLinksAreSafeAndPortable() throws {
        let valid = "folio-note://123e4567-e89b-12d3-a456-426614174000"
        #expect(FormattedPage.allowedLink(valid))
        #expect(!FormattedPage.allowedLink("folio-note://user@123e4567-e89b-12d3-a456-426614174000"))
        #expect(!FormattedPage.allowedLink("folio-note://not-a-uuid"))
        #expect(!FormattedPage.allowedLink("folio-note://123e4567-e89b-12d3-a456-426614174000/other"))
        let page = try FormattedPage(markdown: "[Related](\(valid))")
        #expect(page.markdown() == "[Related](\(valid))")
    }
}
