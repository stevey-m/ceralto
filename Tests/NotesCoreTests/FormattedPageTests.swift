import Foundation
import NotesCore
import Testing

struct FormattedPageTests {
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
}
