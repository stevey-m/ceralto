import AppKit
import NotesCore
import Testing
import WebKit
@testable import Folio

@MainActor
struct WebPreviewTests {
    @Test(arguments: [0, 180], ["photo.jpg", "photo.pngt1769895959", "photo.gift1769895959"])
    func rendersRasterImagesRegardlessOfFilenameAndExpandsOriginalOnClick(imageWidth: Int, filename: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 480, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let type: NSBitmapImageRep.FileType = filename.contains(".png") ? .png : filename.contains(".gif") ? .gif : .jpeg
        let bytes = try #require(bitmap.representation(using: type, properties: [:]))
        let file = directory.appendingPathComponent(filename)
        try bytes.write(to: file)
        let resources = ImportedResources(source: directory.appendingPathComponent("note.md"), root: directory)
        var options = PreviewOptions()
        options.thumbnailSize = imageWidth
        let isLayout = filename != "photo.jpg"
        let source = isLayout ? """
        <div class="joplin-table-wrapper">
        <table role="none"><tr><td><table role="presentation"><tr><td>
        <p>Layout paragraph</p><p><img src="\(filename)"></p>
        <img src="pixel.gift1769895959" width="1" height="1">
        </td></tr></table></td></tr></table>

        ## Markdown heading

        ### Subheading

        - List item

        </div>
        """ : "![Photo](\(filename))"
        let html = try PreviewDocument.html(source: source, format: .markdown,
                                            resources: resources, options: options)
        var expandedURL: URL?
        var error: String?
        let parent = DocumentWebView(html: html, resources: resources, onImage: { expandedURL = $0 }, onError: { error = $0 })
        let coordinator = DocumentWebView.Coordinator(parent: parent)
        let web = DocumentWebView.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        web.frame = NSRect(x: 0, y: 0, width: 1240, height: 600)
        defer {
            web.stopLoading()
            web.configuration.userContentController.removeScriptMessageHandler(forName: "folioImage", contentWorld: .defaultClient)
            window.contentView = nil
        }
        web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        var ready = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            let value = try await web.evaluateJavaScript("document.querySelector('img')?.naturalWidth || 0")
            if let width = value as? Int, width == 640 { ready = true; break }
        }
        #expect(error == nil)
        #expect(ready, "The image must load through the restricted resource handler, including Joplin filename suffixes.")
        guard ready else { return }
        // Sample the same layout frame: native scrollbar changes can resize the page between calls.
        let geometry = try await web.evaluateJavaScript("""
        ({
          image: document.querySelector('img').getBoundingClientRect().width,
          available: document.querySelector('img').parentElement.getBoundingClientRect().width
        })
        """)
        let dimensions = try #require(geometry as? [String: Double])
        let renderedWidth = try #require(dimensions["image"])
        if imageWidth == 0 {
            let availableWidth = try #require(dimensions["available"])
            #expect(availableWidth > (isLayout ? 800 : 1100))
            #expect(abs(renderedWidth - availableWidth) <= 2,
                    "Default images must fill the document width, even beyond the text column and original display size.")
        } else {
            #expect(renderedWidth <= 180)
            #expect(renderedWidth >= 170)
        }
        if isLayout {
            #expect(try await web.evaluateJavaScript("document.querySelector('h3')?.textContent") as? String == "Subheading")
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('img').length") as? Int == 1)
            #expect(try await web.evaluateJavaScript("""
                [...document.querySelectorAll('td')].every(cell => getComputedStyle(cell).borderTopWidth === '0px')
                """) as? Bool == true)
        }
        _ = try await web.evaluateJavaScript("document.querySelector('img').click()")
        for _ in 0..<30 where expandedURL == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(expandedURL?.standardizedFileURL == file.standardizedFileURL)
        let preserved = try Data(contentsOf: file)
        #expect(preserved == bytes)
    }

    @Test func rejectsActiveContentDisguisedAsAnImage() {
        #expect(RasterImageContent.mimeType(in: Data("<html><script>bad()</script></html>".utf8)) == nil)
        #expect(RasterImageContent.mimeType(in: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)) == nil)
    }
}
