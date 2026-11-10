import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct PresentationTests {
    @Test func composedPageKeepsItsSpaceAndProducesASyntheticPreview() async throws {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = LibraryStorage(url: temporary.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Personal")
        let work = Notebook(name: "Work")
        let note = Note(notebookID: notebook.id, title: "A place for your next idea",
            body: "## Less noise. More thought.\n\nA quiet page for the things worth keeping. Write naturally, collect what matters, and find your way back.\n\n**Your words. Your files. Your pace.**\n\n- Capture the thought before it disappears\n\n- Give it a home when you are ready\n\n- Take your library with you",
            tags: ["ideas"], format: .formatted)
        let other = Note(notebookID: work.id, title: "Something worth remembering", body: "The best tools get out of the way.")
        try storage.save(Library(notebooks: [notebook, work], notes: [note, other]))
        let store = NotesStore(storage: storage)
        store.openNote(note.id)
        let suite = "FolioPresentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("System", forKey: "folioTheme")
        defaults.set("System", forKey: "readingFont")
        defaults.set(17.0, forKey: "editorFontSize")
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> PageTextView? {
            if let text = view as? PageTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let page = try #require(editor(in: host))
        #expect(page.frame.width >= 700)
        #expect(page.string.contains("Less noise. More thought."))
        #expect(!page.string.contains("**"))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let destination = package.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent("Folio-compose-preview.png"))
    }
}
