import Foundation
import NotesCore
import Testing

struct ThemePackTests {
    @Test func nativePacksRoundTripAndApplyToPreviewWithoutEnablingScripts() throws {
        for pack in ThemePack.presets + [.dracula] {
            let data = try pack.encoded()
            let restored = try ThemePack.decode(data)
            #expect(restored == pack)
            var options = PreviewOptions()
            options.theme = .custom
            options.palette = restored
            let html = try PreviewDocument.html(source: "# Heading\n\nBody with `code`.", format: .markdown,
                                                 resources: nil, options: options)
            #expect(html.contains("--bg: \(pack.background)"))
            #expect(html.contains("--fg: \(pack.foreground)"))
            #expect(html.contains("--accent: \(pack.accent)"))
            #expect(html.contains("color-scheme: \(pack.isDark ? "dark" : "light")"))
            #expect(html.contains("script-src 'none'"))
            #expect(html.contains("connect-src 'none'"))
        }
    }

    @Test func scriptsCSSUnknownFieldsVersionsPoorContrastAndOversizedPacksAreRejected() throws {
        let valid = try ThemePack.presets[0].encoded()
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["onStart"] = "runCode()"
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try ThemePack.decode(unknownField) }
        #expect(throws: (any Error).self) { try ThemePack.decode(Data("joplin.plugins.register({})".utf8)) }
        #expect(throws: (any Error).self) { try ThemePack.decode(Data(repeating: 32, count: ThemePack.maximumBytes + 1)) }
        for invalidColor in ["red", "#fff", "#000000;body{}", "url(https://example.com)", "</style><script>run()</script>"] {
            var pack = ThemePack.presets[0]
            pack.accent = invalidColor
            var options = PreviewOptions()
            options.palette = pack
            #expect(throws: (any Error).self) {
                try PreviewDocument.html(source: "Body", format: .markdown, resources: nil, options: options)
            }
        }
        var unsupported = ThemePack.presets[0]
        unsupported.version = 2
        #expect(throws: (any Error).self) { try unsupported.encoded() }
        unsupported = ThemePack.presets[0]
        unsupported.foreground = unsupported.background
        #expect(throws: (any Error).self) { try unsupported.encoded() }
    }

    @Test func themeFilesAreBoundedRegularFilesAndNotSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("theme.deltostheme")
        try ThemePack.presets[0].encoded().write(to: file)
        let pack = try ThemePack.load(from: file)
        #expect(pack == ThemePack.presets[0])
        let link = root.appendingPathComponent("link.deltostheme")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try ThemePack.load(from: link) }
        #expect(throws: (any Error).self) { try ThemePack.load(from: root) }
        try Data(repeating: 32, count: ThemePack.maximumBytes + 1).write(to: file)
        #expect(throws: (any Error).self) { try ThemePack.load(from: file) }
    }
}
