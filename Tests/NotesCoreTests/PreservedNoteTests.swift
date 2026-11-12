import Foundation
import NotesCore
import SwiftSoup
import Testing

struct PreservedNoteTests {
    private func identifier(for text: String, in document: PreservedNoteDocument) throws -> String {
        let rendered = try SwiftSoup.parseBodyFragment(document.renderedHTML)
        let element = try #require(rendered.select("[data-ceralto-edit]").first { try $0.text() == text })
        return try element.attr("data-ceralto-edit")
    }

    @Test func htmlTextEditsPreserveOriginalLayoutAttributesAndResources() throws {
        let source = """
        <!--original--><table role='none' width='100%'><tr><td style='padding: 20px'>
        <p class='email'>Before <b>chosen &amp; words</b> after</p>
        <p><img src='../_resources/original.png' width='640'></p>
        </td></tr></table><details open><summary>More</summary><p>Keep this</p></details>
        """
        let document = try PreservedNoteDocument(source: source, format: .html)
        #expect(try document.applying([:]) == source)
        let id = try identifier(for: "chosen & words", in: document)
        let edited = try document.applying([id: "edited &amp; words"])
        #expect(edited == source.replacingOccurrences(of: "chosen &amp; words", with: "edited &amp; words"))
        let sized = try document.applying([id: "<span style=\"font-size:24px\">chosen &amp; words</span>"])
        let restored = try SwiftSoup.parse(sized)
        #expect(try restored.select("b span[style]").text() == "chosen & words")
        #expect(try restored.select("table").attr("role") == "none")
        #expect(try restored.select("td").attr("style") == "padding: 20px")
        #expect(try restored.select("img").attr("src") == "../_resources/original.png")
        #expect(try restored.select("details").hasAttr("open"))
        #expect(sized.contains("<!--original-->"))
    }

    @Test func mixedMarkdownEditsTouchOnlyTheirSourceFragmentsAndKeepCodeLiteral() throws {
        let source = """
        <table role="none"><tr><td><p>Email words</p><img src="local.png"></td></tr></table>

        ### A heading

        Ordinary **bold words** and [a link](https://example.test).

        ```html
        <p>Code is not an HTML layout</p>
        ```
        """
        let document = try PreservedNoteDocument(source: source, format: .markdown)
        let email = try identifier(for: "Email words", in: document)
        let bold = try identifier(for: "bold words", in: document)
        let result = try document.applying([email: "Revised email", bold: "<u>edited words</u>"])
        #expect(result.contains("### A heading"))
        #expect(result.contains("**<span><u>edited words</u></span>**"))
        #expect(result.contains("[a link](https://example.test)"))
        #expect(result.contains("```html\n<p>Code is not an HTML layout</p>\n```"))
        #expect(result.contains("<img src=\"local.png\">"))
        let reopened = try PreservedNoteDocument(source: result, format: .markdown)
        #expect(try identifier(for: "edited words", in: reopened).isEmpty == false)
    }

    @Test func unicodeEntitiesEscapesAndRepeatedTextHaveIndependentSourceMappings() throws {
        let source = "### Caf\u{e9} \u{1f600}\n\nSame **Same** and &amp; \\*literal\\*."
        let document = try PreservedNoteDocument(source: source, format: .markdown)
        let rendered = try SwiftSoup.parseBodyFragment(document.renderedHTML)
        let bold = try #require(rendered.select("strong [data-ceralto-edit]").first())
        let id = try bold.attr("data-ceralto-edit")
        let result = try document.applying([id: "different *text*"])
        #expect(result.hasPrefix("### Caf\u{e9} \u{1f600}\n\nSame **"))
        let text = try SwiftSoup.parse(PreviewDocument.markdownHTML(result)).text()
        #expect(text.contains("Same different *text* and & *literal*."))
    }

    @Test func emptyParagraphCanBeEditedAgainAfterDeletingItsText() throws {
        let initial = try PreservedNoteDocument(source: "<p>Delete me</p><p><br></p>", format: .html)
        let id = try identifier(for: "Delete me", in: initial)
        let deleted = try initial.applying([id: ""])
        let reopened = try PreservedNoteDocument(source: deleted, format: .html)
        let empty = try identifier(for: "", in: reopened)
        let restored = try reopened.applying([empty: "New words"])
        #expect(try SwiftSoup.parse(restored).select("p").first()?.text() == "New words")
    }

    @Test func removingInheritedFormattingSurvivesSavingAndBothEditorPaths() throws {
        let source = "<p><b><i>Selected words</i></b></p>"
        let document = try PreservedNoteDocument(source: source, format: .html)
        let id = try identifier(for: "Selected words", in: document)
        let changed = try document.applying([id: "<span style='font-weight:normal;font-style:normal;font-size:23px'>Selected words</span>"])
        let preview = try PreviewDocument.html(source: changed, format: .html, resources: nil)
        #expect(preview.contains("font-weight:normal;font-style:normal;font-size:23.0px"))
        let page = try FormattedPage(html: changed)
        let run = try #require(page.blocks.first?.runs.first)
        #expect(!run.bold && !run.italic && run.fontSize == 23)
        #expect(try PreservedNoteDocument(source: changed, format: .html).applying([:]) == changed)
    }

    @Test func quotedTagsCommentsAndRawTextDoNotShiftVisibleTextPatches() throws {
        let source = """
        <script>const text = '<p>Not editable</p>';</script><!--keep > this-->
        <p title='a > b'>First &amp; text</p><img src='original.png'><p>Second</p>
        """
        let document = try PreservedNoteDocument(source: source, format: .html)
        let id = try identifier(for: "Second", in: document)
        #expect(try document.applying([id: "Edited"]) == source.replacingOccurrences(of: ">Second<", with: ">Edited<"))
        let rendered = try SwiftSoup.parseBodyFragment(document.renderedHTML)
        #expect(try rendered.select("script [data-ceralto-edit]").isEmpty())
        #expect(throws: (any Error).self) {
            try PreservedNoteDocument(source: "<p>Body</p><!--unfinished", format: .html)
        }
    }

    @Test func editedFragmentsRejectActiveContentUnknownIdentifiersAndLayoutReplacement() throws {
        let document = try PreservedNoteDocument(source: "<p>Keep me</p>", format: .html)
        let id = try identifier(for: "Keep me", in: document)
        for html in ["<script>alert(1)</script>", "<img src='https://example.test/tracker'>",
                     "<table><tr><td>changed</td></tr></table>", "<span onclick='alert(1)'>No</span>",
                     "<span style='background:url(https://example.test)'>No</span>"] {
            #expect(throws: (any Error).self) { try document.applying([id: html]) }
        }
        #expect(throws: (any Error).self) { try document.applying(["old-note": "No"]) }
        #expect(try document.applying([:]) == "<p>Keep me</p>")
        let safe = try PreviewDocument.html(source: document.renderedHTML, format: .html, resources: nil,
                                            editableIDs: document.editableIDs)
        #expect(safe.contains("data-ceralto-edit"))
        #expect(safe.contains("script-src 'none'"))
        let ordinary = try PreviewDocument.html(source: document.renderedHTML, format: .html, resources: nil)
        #expect(!ordinary.contains("data-ceralto-edit"))
    }
}
