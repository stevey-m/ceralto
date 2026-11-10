import AppKit
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

struct AppearanceTests {
    @Test func defaultAppearanceIsNativeAndLegacyDraculaStillLoads() {
        let defaults = PreviewOptions()
        #expect(defaults.theme == .system)
        #expect(defaults.font == .system)
        #expect(defaults.accent == .gold)
        #expect(FolioTheme(rawValue: "Dracula") == .dracula)
        #expect(FolioTheme.light.colorScheme == .light)
        #expect(FolioTheme.dark.colorScheme == .dark)
        #expect(FolioTheme.system.colorScheme == nil)
    }

    @Test(arguments: FolioTheme.allCases)
    func previewHonoursAppearanceAndAccent(theme: FolioTheme) throws {
        var options = PreviewOptions()
        options.theme = theme
        options.accent = .blue
        let html = try PreviewDocument.html(source: "[Link](https://example.com)", format: .markdown,
                                            resources: nil, options: options)
        #expect(html.contains("color-scheme: \(theme.cssColorScheme);"))
        let expected = theme == .dark || theme == .dracula ? FolioAccent.blue.darkHex : FolioAccent.blue.lightHex
        #expect(html.contains("--accent: \(expected);"))
        #expect(!html.contains("<script"))
    }

    @MainActor
    @Test(arguments: [FolioTheme.light, .dark])
    func renderedPreviewUsesSelectedSchemeNotTheOperatingSystem(theme: FolioTheme) async throws {
        var options = PreviewOptions()
        options.theme = theme
        options.accent = .rose
        let html = try PreviewDocument.html(source: "[Link](https://example.com)", format: .markdown,
                                            resources: nil, options: options)
        let coordinator = DocumentWebView.Coordinator(parent: DocumentWebView(
            html: html, resources: nil, onImage: { _ in }, onError: { Issue.record("\($0)") }))
        let web = DocumentWebView.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        defer { DocumentWebView.dismantleNSView(web, coordinator: coordinator); window.contentView = nil }
        web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            let ready = try await web.evaluateJavaScript("document.querySelector('a') !== null")
            if ready as? Bool == true { loaded = true; break }
        }
        try #require(loaded)
        let scheme = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).colorScheme")
        #expect(scheme as? String == theme.cssColorScheme)
        let colour = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('a')).color")
        #expect(colour as? String == (theme == .dark ? "rgb(255, 146, 183)" : "rgb(179, 51, 98)"))
    }
}
