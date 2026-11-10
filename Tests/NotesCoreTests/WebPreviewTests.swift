import AppKit
import NotesCore
import Testing
import WebKit
@testable import Folio

@MainActor
struct WebPreviewTests {
    @Test(arguments: [0, 180]) func rendersReadableJPEGAndExpandsOriginalOnClick(imageWidth: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 480, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let file = directory.appendingPathComponent("photo.jpg")
        try bytes.write(to: file)
        let resources = ImportedResources(source: directory.appendingPathComponent("note.md"), root: directory)
        var options = PreviewOptions()
        options.thumbnailSize = imageWidth
        let html = try PreviewDocument.html(source: "![Photo](photo.jpg)", format: .markdown,
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
        #expect(ready, "The original JPEG must load through the restricted resource handler.")
        guard ready else { return }
        // Sample the same layout frame: native scrollbar changes can resize the page between calls.
        let geometry = try await web.evaluateJavaScript("""
        ({
          image: document.querySelector('img').getBoundingClientRect().width,
          available: document.querySelector('main').getBoundingClientRect().width
        })
        """)
        let dimensions = try #require(geometry as? [String: Double])
        let renderedWidth = try #require(dimensions["image"])
        if imageWidth == 0 {
            let availableWidth = try #require(dimensions["available"])
            #expect(availableWidth > 1100)
            #expect(abs(renderedWidth - availableWidth) <= 2,
                    "Default images must fill the document width, even beyond the text column and original display size.")
        } else {
            #expect(renderedWidth <= 180)
            #expect(renderedWidth >= 170)
        }
        _ = try await web.evaluateJavaScript("document.querySelector('img').click()")
        for _ in 0..<30 where expandedURL == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(expandedURL?.standardizedFileURL == file.standardizedFileURL)
        let preserved = try Data(contentsOf: file)
        #expect(preserved == bytes)
    }
}
