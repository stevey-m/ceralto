import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct DraculaWorkspaceTests {
    @Test func richPastePersistsInTheRealDraculaWindowAndPaletteReverts() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "DeltosDracula-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Dracula", forKey: "folioTheme")
        defaults.set("Gold", forKey: "folioAccent")
        let notebook = Notebook(name: "Personal/Ideas")
        let note = Note(notebookID: notebook.id, title: "A notebook without lock-in", body: "Replace this", format: .formatted)
        let storage = LibraryStorage(url: folder.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.openNote(note.id)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        defer { window.contentView = nil }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if descendants(host).contains(where: { $0 is PageTextView }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(descendants(host).compactMap { $0 as? PageTextView }.first)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let picture = try illustration()
        board.setString("""
        <h1>Make yourself at home</h1>
        <p>Write with <strong>bold ideas</strong>, <em>gentle emphasis</em> and <u>important details</u>.
        Your words and pictures travel together.</p>
        <p><img src="data:image/png;base64,\(picture.base64EncodedString())" alt="Portable notes"></p>
        <h2>Small details, better writing</h2>
        <ul><li>Copy rich text and embedded images.</li><li>Keep a readable, complete Dracula workspace.</li></ul>
        <p><a href="https://github.com/stevey-m/folio">Open source. Ordinary files. Your notes.</a></p>
        """, forType: .html)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.paste(from: board)
        let pastedHeadingFont = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(pastedHeadingFont.pointSize >= 25)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.errorMessage == nil)
        let persisted = try #require(storage.load()?.notes.first)
        let page = try FormattedPage(markdown: persisted.body)
        #expect(page.blocks.first?.style == .heading1)
        #expect(page.blocks.flatMap(\.runs).contains { $0.bold && $0.text == "bold ideas" })
        let image = try #require(page.blocks.flatMap(\.runs).compactMap(\.image).first)
        let resources = ImportedResources(source: try #require(persisted.importedSourceURL), root: try #require(persisted.importedRootURL))
        let imageURL = try #require(resources.localURL(for: image))
        let bytes = try Data(contentsOf: imageURL)
        #expect(bytes == picture)
        #expect(close(window.backgroundColor, to: NSColor(FolioPalette.background)))
        #expect(close(try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor), to: NSColor(FolioPalette.selection)))
        #expect(close(try #require(editor.linkTextAttributes?[.foregroundColor] as? NSColor), to: NSColor(FolioPalette.purple)))
        let heading = try #require(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(close(heading, to: NSColor(FolioPalette.purple)))
        let headingFont = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(headingFont.pointSize >= 25)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(fraction(bitmap, matching: NSColor(FolioPalette.background)) > 0.25)
        #expect(fraction(bitmap, matching: NSColor(FolioPalette.sidebar)) > 0.05)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: package.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try png.write(to: package.appendingPathComponent("dist/Deltos-dracula-clipboard-preview.png"))
        defaults.set("Rose", forKey: "folioDraculaAccent")
        try await Task.sleep(for: .milliseconds(150))
        let rose = NSColor(FolioAccent.rose.color(for: .dark))
        #expect(close(try #require(editor.linkTextAttributes?[.foregroundColor] as? NSColor), to: rose))
        #expect(close(try #require(editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor), to: rose))
        defaults.set("Light", forKey: "folioTheme")
        try await Task.sleep(for: .milliseconds(200))
        #expect(descendants(host).compactMap { $0 as? PageTextView }.first === editor)
        #expect(editor.string.contains("Make yourself at home"))
        #expect(!close(window.backgroundColor, to: NSColor(FolioPalette.background)))
        #expect(close(try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor), to: .selectedTextBackgroundColor))
        #expect(defaults.string(forKey: "folioAccent") == "Gold")
        #expect(defaults.string(forKey: "folioDraculaAccent") == "Rose")
        #expect(!store.hasUnsavedChanges)
    }

    @Test func sourceEditorUsesDraculaSelectionAndReturnsToNativeColors() throws {
        let editor = SourceTextView()
        FolioPalette.style(editor, dracula: true)
        #expect(close(editor.backgroundColor, to: NSColor(FolioPalette.background)))
        #expect(close(try #require(editor.selectedTextAttributes[.foregroundColor] as? NSColor), to: NSColor(FolioPalette.foreground)))
        FolioPalette.style(editor, dracula: false)
        #expect(close(editor.backgroundColor, to: .textBackgroundColor))
        #expect(close(try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor), to: .selectedTextBackgroundColor))
    }

    @Test func settingsUsesThePaletteAcrossNavigationAndForms() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "DeltosDraculaSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Dracula", forKey: "folioTheme")
        try LibraryStorage(url: folder.appendingPathComponent("library.json")).save(.starter())
        let store = NotesStore(storage: LibraryStorage(url: folder.appendingPathComponent("library.json")), preferences: defaults)
        let host = NSHostingView(rootView: SettingsView(section: .appearance).environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 760)
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let closeButton = try #require(descendants(host).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "deltos-close-settings" })
        let buttonFrame = closeButton.convert(closeButton.bounds, to: host)
        let header = NSRect(x: 0, y: buttonFrame.midY - 20, width: host.bounds.width, height: 40)
        let headerBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: header))
        host.cacheDisplay(in: header, to: headerBitmap)
        #expect(fraction(headerBitmap, matching: NSColor(FolioPalette.background)) > 0.65,
                "The fixed header must use Dracula's surface, regardless of how many form controls fill the window.")
        #expect(fraction(bitmap, matching: NSColor(FolioPalette.sidebar)) > 0.15)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: package.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try png.write(to: package.appendingPathComponent("dist/Deltos-dracula-settings-preview.png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func close(_ first: NSColor, to second: NSColor) -> Bool {
        guard let a = first.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.015 &&
            abs(a.greenComponent - b.greenComponent) < 0.015 &&
            abs(a.blueComponent - b.blueComponent) < 0.015
    }

    private func fraction(_ bitmap: NSBitmapImageRep, matching color: NSColor) -> Double {
        guard let expected = color.usingColorSpace(bitmap.colorSpace) else { Issue.record("Cannot compare the screenshot colour profile."); return 0 }
        var matches = 0
        var total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                total += 1
                // colorAt returns raw calibrated components even when the bitmap is tagged Display P3.
                if let pixel = bitmap.colorAt(x: x, y: y),
                   abs(pixel.redComponent - expected.redComponent) < 0.015,
                   abs(pixel.greenComponent - expected.greenComponent) < 0.015,
                   abs(pixel.blueComponent - expected.blueComponent) < 0.015 { matches += 1 }
            }
        }
        return Double(matches) / Double(total)
    }

    private func illustration() throws -> Data {
        let image = NSImage(size: NSSize(width: 580, height: 150))
        image.lockFocus()
        NSColor(FolioPalette.sidebar).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 580, height: 150), xRadius: 16, yRadius: 16).fill()
        for (index, label) in ["WRITE", "COPY", "KEEP"].enumerated() {
            let x = 25 + index * 185
            NSColor(FolioPalette.selection).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 30, width: 160, height: 90), xRadius: 10, yRadius: 10).fill()
            (label as NSString).draw(at: NSPoint(x: x + 24, y: 70), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor(FolioPalette.purple)])
            ("Your notes, intact." as NSString).draw(at: NSPoint(x: x + 24, y: 47), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(FolioPalette.foreground)])
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
