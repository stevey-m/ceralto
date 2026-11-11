import AppKit
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

struct AppearanceTests {
    @MainActor
    @Test func textSizeKeysUpdateTheLiveEditorAndPersistWithoutChangingTheNote() async throws {
        _ = NSApplication.shared
        let suite = "DeltosTextSize-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = FormattingActions()
        var source = "Words"
        var writes = 0
        let host = NSHostingView(rootView: TextSizeFixture(actions: actions, source: { source }) {
            source = $0; writes += 1
        }.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<100 where actions.editor == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(actions.editor)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" typed", replacementRange: editor.selectedRange())
        let savedSource = source
        let savedWrites = writes
        let selection = editor.selectedRange()
        func key(_ character: String, flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: code))
        }
        func waitForSize(_ size: Double) async throws {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if editor.pageFontSize == size { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(editor.pageFontSize == size)
            let font = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(abs(font.pointSize - size) < 0.01)
        }
        let plus = try key("+", flags: [.command, .shift], code: 24)
        let minus = try key("-", flags: .command, code: 27)
        host.layoutSubtreeIfNeeded()
        try #require(window.performKeyEquivalent(with: plus))
        try await waitForSize(16)
        #expect(defaults.double(forKey: "editorFontSize") == 16)
        try #require(window.performKeyEquivalent(with: minus))
        try await waitForSize(15)
        #expect(defaults.double(forKey: "editorFontSize") == 15)
        defaults.set(28.0, forKey: "editorFontSize")
        try await waitForSize(28)
        #expect(!window.performKeyEquivalent(with: plus))
        #expect(defaults.double(forKey: "editorFontSize") == 28)
        defaults.set(11.0, forKey: "editorFontSize")
        try await waitForSize(11)
        #expect(!window.performKeyEquivalent(with: minus))
        #expect(defaults.double(forKey: "editorFontSize") == 11)
        #expect(editor.string == "Words typed")
        #expect(editor.selectedRange() == selection)
        #expect(editor.undoManager?.canUndo == true)
        #expect(source == savedSource)
        #expect(writes == savedWrites)
    }

    @Test(arguments: FolioAccent.allCases)
    func draculaAccentIsAnOptionalChoiceRatherThanALock(accent: FolioAccent) throws {
        var options = PreviewOptions()
        options.theme = .dracula
        options.draculaAccent = accent
        let html = try PreviewDocument.html(source: "[Link](https://example.com)", format: .markdown,
                                            resources: nil, options: options)
        #expect(html.contains("--accent: \(accent.darkHex);"))
        #expect(html.contains("--bg: #282a36;"))
    }

    private struct TextSizeFixture: View {
        @AppStorage("editorFontSize") private var fontSize = 15.0
        let actions: FormattingActions
        let source: () -> String
        let onChange: (String) -> Void

        var body: some View {
            VStack {
                TextSizeButtons()
                NativePageView(html: source(), resources: nil, size: fontSize, family: .system, dracula: false,
                               actions: actions, onChange: onChange, onError: { Issue.record("\($0)") },
                               currentSource: source)
            }
        }
    }

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
        let expected = theme == .dracula ? "#bd93f9" : theme == .dark ? FolioAccent.blue.darkHex : FolioAccent.blue.lightHex
        #expect(html.contains("--accent: \(expected);"))
        #expect(!html.contains("<script"))
    }

    @MainActor
    @Test(arguments: [FolioTheme.light, .dark, .dracula])
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
        #expect(colour as? String == (theme == .dracula ? "rgb(189, 147, 249)" : theme == .dark ? "rgb(255, 146, 183)" : "rgb(179, 51, 98)"))
        if theme == .dracula {
            let background = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
            #expect(background as? String == "rgb(40, 42, 54)")
            let foreground = try await web.evaluateJavaScript("getComputedStyle(document.body).color")
            #expect(foreground as? String == "rgb(248, 248, 242)")
        }
    }
}
