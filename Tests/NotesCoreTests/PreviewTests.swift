import Foundation
import NotesCore
import Testing

struct PreviewTests {
    @Test func preservesMixedMarkdownAndNestedPresentationTablesWithoutTrackingPixels() throws {
        let resources = ImportedResources(source: URL(fileURLWithPath: "/tmp/vault/Work/Import/note.md"),
                                          root: URL(fileURLWithPath: "/tmp/vault"))
        let source = """
        <div class="joplin-table-wrapper">
        <table role="none" class="jop-noMdConv"><tr><td>
        <table role="presentation"><tr><td><p>Layout paragraph</p>
        <img src="../../_resources/photo.pngt1769895959">
        <img src="../../_resources/pixel.gift1769895959" width="1" height="1">
        </td></tr></table></td></tr></table>

        ## Markdown heading

        ### Subheading

        - List item with **emphasis**

        </div>
        """
        #expect(throws: JoplinImportError.self) { try FormattedPage(markdown: source) }
        let html = try PreviewDocument.html(source: source, format: .markdown, resources: resources)
        #expect(html.contains("<table role=\"none\">"))
        #expect(html.contains("<table role=\"presentation\">"))
        #expect(html.contains("<h2>Markdown heading</h2>"))
        #expect(html.contains("<h3>Subheading</h3>"))
        #expect(html.contains("<strong>emphasis</strong>"))
        #expect(html.contains("folio-resource://local/_resources/photo.pngt1769895959"))
        #expect(!html.contains("pixel.gift"))
        #expect(!html.contains("class=\"folio-table-scroll\""))
        #expect(!html.contains("jop-noMdConv"))
        #expect(html.contains("script-src 'none'; connect-src 'none'"))
    }

    @Test func preservesJoplinStyleLineBreaksAndSemanticTables() throws {
        let source = """
        First line
        Second line

        | Course | Objectives | |
        | --- | ---: | --- |
        | **Example** | First<br>Second | |
        """
        let html = try PreviewDocument.html(source: source, format: .markdown, resources: nil)
        #expect(html.contains("First line<br"))
        #expect(html.contains("class=\"folio-table-scroll\""))
        #expect(html.contains("<table>"))
        #expect(html.contains("align=\"right\""))
        #expect(html.contains("strong,em { color: inherit; }"))
        #expect(!html.contains("min-width: 60px"))
        let commonMark = try PreviewDocument.markdownHTML("First line\nSecond line")
        #expect(!commonMark.contains("<br"))
    }

    @Test func rendersCommonMarkAndGFM() throws {
        let html = try PreviewDocument.markdownHTML("""
        # A heading

        - parent
          - child with **bold**

        | Name | Value |
        | --- | --- |
        | one | two |

        - [x] Done
        - [ ] Not done

        ~~removed~~ and [reference][ref]

        [ref]: https://example.com

        ```swift
        let x = "<tag>"
        ```
        """)
        #expect(html.contains("<table>"))
        #expect(html.components(separatedBy: "<ul>").count >= 3)
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("checkbox"))
        #expect(html.contains("<del>removed</del>"))
        #expect(html.contains("https://example.com"))
        #expect(html.contains("&lt;tag&gt;"))
    }

    @Test func resolvesInlineReferenceAndHTMLImagesAsThumbnails() throws {
        let resources = ImportedResources(source: URL(fileURLWithPath: "/tmp/vault/Work/note.md"),
                                          root: URL(fileURLWithPath: "/tmp/vault"))
        let html = try PreviewDocument.html(source: """
        inline ![first](../assets/photo%20one.jpg "Caption") text

        ![reference][photo]

        [photo]: ../assets/two.jpeg

        <img src="../assets/three.jpg" width="12" height="8" onerror="alert(1)">
        """, format: .markdown, resources: resources)
        #expect(html.components(separatedBy: "class=\"folio-thumbnail\"").count == 4)
        #expect(html.contains("folio-resource://local/assets/photo%20one.jpg"))
        #expect(html.contains("folio-resource://local/assets/two.jpeg"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("width=\"1\""))
        #expect(html.contains("max-height: none"))
    }

    @Test func sanitizesHTMLAndDisablesExternalRequests() throws {
        let html = try PreviewDocument.html(source: """
        <html><head><title>Test</title><style>body{display:none}</style></head>
        <body onload="bad()"><h1>Hello</h1><script>alert('bad')</script>
        <iframe src="https://example.com"></iframe><svg onload="bad()"></svg>
        <img src="https://example.com/tracker.jpg" alt="Remote">
        <a href="javascript:alert(1)">bad</a><a href="https://example.com">good</a>
        <table><tr><td>Cell</td></tr></table><details><summary>More</summary>Text</details>
        </body></html>
        """, format: .html, resources: nil)
        #expect(html.contains("<h1>Hello</h1>"))
        #expect(html.contains("<td>Cell</td>"))
        #expect(html.contains("<details>"))
        #expect(html.contains("external or missing resource"))
        #expect(!html.contains("tracker.jpg"))
        #expect(!html.contains("javascript:"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<iframe"))
        #expect(!html.contains("onload"))
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains("https://example.com"))
    }

    @Test func preventsResourceTraversal() throws {
        let resources = ImportedResources(source: URL(fileURLWithPath: "/tmp/vault/note.md"),
                                          root: URL(fileURLWithPath: "/tmp/vault"))
        #expect(resources.localURL(for: "../secret.jpg") == nil)
        #expect(resources.localURL(for: "file:///etc/passwd") == nil)
        #expect(resources.fileURL(for: URL(string: "folio-resource://local/../secret")!) == nil)
        #expect(resources.fileURL(for: URL(string: "folio-resource://local/%2e%2e/secret")!) == nil)
        #expect(resources.previewURL(for: "assets/test.jpg")?.scheme == "folio-resource")
        #expect(resources.localURL(for: "https://example.com/test.jpg") == nil)
    }

    @Test func previewPreferenceBounds() throws {
        var options = PreviewOptions()
        options.thumbnailSize = 1
        options.fontSize = 100
        options.fullWidth = true
        let html = try PreviewDocument.html(source: "Hello", format: .markdown, resources: nil, options: options)
        #expect(html.contains("max-height: 64px"))
        #expect(html.contains("font: 32.0px"))
        #expect(html.contains("max-width: none"))
    }

    @Test func treePreservesNestedNotebooksAndDuplicateNames() {
        let notebooks = [Notebook(name: "Work"), Notebook(name: "Work/Meetings"),
                         Notebook(name: "Work/Projects/Atlas"), Notebook(name: "Personal"), Notebook(name: "Work")]
        let roots = NotebookBranch.build(notebooks)
        #expect(roots.count == 2)
        let work = roots.first { $0.name == "Work" }
        #expect(work?.notebooks.count == 2)
        #expect(work?.descendants.count == 4)
        #expect(work?.children.map(\.name) == ["Meetings", "Projects"])
        #expect(work?.children.last?.children.first?.name == "Atlas")
    }
}
