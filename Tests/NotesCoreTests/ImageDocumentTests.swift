import AppKit
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

@Suite(.serialized)
@MainActor
struct ImageDocumentTests {
    @Test func originalCanvasFitsWindowZoomsPansAndRefits() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 160, height: 100))
        image.addRepresentation(bitmap)
        let scroll = ImageDocumentScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.scrollerStyle = .overlay
        scroll.show(image)
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.picture.frame.size == NSSize(width: 1600, height: 1000))
        #expect(scroll.allowsMagnification)
        #expect(abs(scroll.magnification - 0.5) < 0.02)
        scroll.magnification = 1.5
        scroll.contentView.scroll(to: NSPoint(x: 250, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.x > 0)
        scroll.setFrameSize(NSSize(width: 900, height: 600))
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.magnification == 1.5, "Resizing must not discard a deliberate zoom.")
        scroll.fitToWindow()
        #expect(abs(scroll.magnification - 0.5625) < 0.02)
        scroll.setFrameSize(NSSize(width: 640, height: 480))
        scroll.layoutSubtreeIfNeeded()
        #expect(abs(scroll.magnification - 0.4) < 0.02)
    }

    @Test func previewImageOpensInDocumentWithoutASheetAndPreservesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let file = directory.appendingPathComponent("photo.jpg")
        try bytes.write(to: file)
        var note = Note(notebookID: UUID(), title: "Photo", body: "![Photo](photo.jpg)")
        note.importedSourceURL = directory.appendingPathComponent("note.md")
        note.importedRootURL = directory
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")))
        let host = NSHostingView(rootView: MarkdownPreview(note: note).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let web = try #require(find(WKWebView.self, in: host))
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let value = try await web.evaluateJavaScript("document.querySelector('img')?.naturalWidth || 0")
            if value as? Int == 1600 { loaded = true; break }
        }
        try #require(loaded)
        _ = try await web.evaluateJavaScript("document.querySelector('img').click()")
        for _ in 0..<50 {
            if find(ImageDocumentScrollView.self, in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        host.layoutSubtreeIfNeeded()
        let canvas = try #require(find(ImageDocumentScrollView.self, in: host))
        #expect(window.attachedSheet == nil)
        #expect(canvas.frame.width >= 790)
        #expect(canvas.picture.image != nil)
        #expect(find(WKWebView.self, in: host) === web, "Returning must retain the note's web view and scroll position.")
        let preserved = try Data(contentsOf: file)
        #expect(preserved == bytes)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
