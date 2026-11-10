import AppKit
import Foundation
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

struct LiveMarkdownTests {
    @Test func editsFilesInPlacePreservingFrontMatterLineEndingsAndOtherFiles() throws {
        try fixture { folder in
            try folder.createDirectory(at: "Work")
            let original = "---\r\ncustom: [one, two]\r\nunknown-property: keep\r\n---\r\n\r\n# Original\r\n"
            try folder.createNote(at: "Work/Idea.md", text: original)
            let source = try folder.read("Work/Idea.md")
            #expect(source.text == original)
            let edited = original.replacingOccurrences(of: "# Original", with: "# Changed")
            let saved = try folder.save(edited, at: "Work/Idea.md", expectedDigest: source.digest)
            #expect(saved.text == edited)
            #expect(saved.digest != source.digest)
            let bytes = try Data(contentsOf: folder.url(for: "Work/Idea.md"))
            #expect(bytes == Data(edited.utf8))
            let entries = try folder.entries()
            #expect(entries.map(\.path) == ["Work", "Work/Idea.md"])
        }
    }

    @Test func externalEditsAndDeletionsNeverGetOverwrittenByStaleDrafts() throws {
        try fixture { folder in
            try folder.createNote(at: "Idea.md", text: "Original")
            let source = try folder.read("Idea.md")
            try Data("External".utf8).write(to: folder.url(for: "Idea.md"), options: .atomic)
            #expect(throws: (any Error).self) { try folder.save("Draft", at: "Idea.md", expectedDigest: source.digest) }
            #expect(try folder.read("Idea.md").text == "External")
            try FileManager.default.removeItem(at: folder.url(for: "Idea.md"))
            #expect(throws: (any Error).self) { try folder.save("Draft", at: "Idea.md", expectedDigest: source.digest) }
            #expect(!FileManager.default.fileExists(atPath: folder.root.appendingPathComponent("Idea.md").path))
        }
    }

    @Test func movesRetainBytesNeverOverwriteAndRejectCyclesOrInvalidPaths() throws {
        try fixture { folder in
            try folder.createDirectory(at: "Study")
            try folder.createDirectory(at: "Work")
            try folder.createNote(at: "Study/Idea.md", text: "Original")
            try folder.createNote(at: "Work/Idea.md", text: "Other")
            #expect(throws: (any Error).self) { try folder.move("Study/Idea.md", to: "Work/Idea.md") }
            #expect(throws: (any Error).self) { try folder.move("Study", to: "Study/Child") }
            #expect(throws: (any Error).self) { try folder.move("Study/Idea.md", to: "Work/Idea.txt") }
            try folder.move("Study", to: "Work/Learning")
            #expect(try folder.read("Work/Learning/Idea.md").text == "Original")
            #expect(try folder.read("Work/Idea.md").text == "Other")
            for path in ["../escape.md", "/absolute.md", ".obsidian/private.md", "Bad//file.md", "Bad/../file.md"] {
                #expect(throws: (any Error).self) { try folder.createNote(at: path) }
            }
            #expect(throws: (any Error).self) { try folder.createNote(at: "Work/Idea.md", text: "Overwrite") }
        }
    }

    @Test func symlinksHiddenFilesAndNonMarkdownFilesAreNotEditable() throws {
        try fixture { folder in
            try folder.createNote(at: "Visible.md", text: "Keep")
            try Data("hidden".utf8).write(to: folder.root.appendingPathComponent(".hidden.md"))
            try Data([0, 1, 2]).write(to: folder.root.appendingPathComponent("image.png"))
            try FileManager.default.createSymbolicLink(at: folder.root.appendingPathComponent("Linked.md"),
                                                       withDestinationURL: folder.root.appendingPathComponent("Visible.md"))
            let entries = try folder.entries()
            #expect(entries.map(\.path) == ["Visible.md"])
            #expect(throws: (any Error).self) { try folder.read("Linked.md") }
            #expect(throws: (any Error).self) { try folder.read("image.png") }
            #expect(throws: (any Error).self) { try folder.createNote(at: ".hidden.md") }
        }
    }

    @Test func invalidUTF8AndOversizedNotesFailWithoutConversion() throws {
        try fixture { folder in
            try Data([0xff, 0xfe, 0x80]).write(to: folder.root.appendingPathComponent("Invalid.md"))
            #expect(throws: (any Error).self) { try folder.read("Invalid.md") }
            try Data().write(to: folder.root.appendingPathComponent("Large.md"))
            let handle = try FileHandle(forWritingTo: folder.root.appendingPathComponent("Large.md"))
            try handle.truncate(atOffset: UInt64(LiveMarkdownFolder.maximumNoteBytes + 1))
            try handle.close()
            #expect(throws: (any Error).self) { try folder.read("Large.md") }
        }
    }

    private func fixture(_ action: (LiveMarkdownFolder) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(LiveMarkdownFolder(root: root))
    }
}

@MainActor
struct LiveMarkdownStoreTests {
    @Test func externalChangesReloadCleanNotesButPreserveDirtyDraftsAndAllowSeparateCopies() async throws {
        try await fixture { model, folder, _, _ in
            model.select("Idea.md")
            try Data("External one".utf8).write(to: folder.root.appendingPathComponent("Idea.md"))
            await model.refresh()
            #expect(model.text == "External one")
            #expect(!model.dirty)
            model.text = "My draft"
            try Data("External two".utf8).write(to: folder.root.appendingPathComponent("Idea.md"))
            await model.refresh()
            #expect(model.text == "My draft")
            #expect(model.dirty)
            #expect(model.conflict)
            #expect(!model.save())
            #expect(try folder.read("Idea.md").text == "External two")
            model.create(path: "Recovered.md", directory: false, copyDraft: true)
            #expect(try folder.read("Recovered.md").text == "My draft")
            #expect(!model.dirty)
            #expect(!model.conflict)
            model.select("Idea.md")
            #expect(model.text == "External two")
        }
    }

    @Test func externalRenamePreservesDraftAndExistingLibraryIsNeverChanged() async throws {
        try await fixture { model, folder, libraryURL, original in
            model.select("Idea.md")
            model.text = "Draft"
            try folder.move("Idea.md", to: "Renamed.md")
            await model.refresh()
            #expect(model.text == "Draft")
            #expect(model.conflict)
            #expect(!model.save())
            let bytes = try Data(contentsOf: libraryURL)
            #expect(bytes == original)
            #expect(throws: (any Error).self) { try model.open(libraryURL.deletingLastPathComponent(), avoiding: libraryURL) }
            model.create(path: "Copy.md", directory: false, copyDraft: true)
            #expect(try folder.read("Copy.md").text == "Draft")
        }
    }

    @Test func draftDecisionsOnlyPermitClosingAfterSaveOrExplicitDiscard() async throws {
        try await fixture { model, folder, _, _ in
            model.select("Idea.md")
            model.text = "Keep my unsaved draft"
            #expect(!model.resolveDraft(.cancel))
            #expect(model.dirty)
            #expect(model.resolveDraft(.save))
            #expect(try folder.read("Idea.md").text == "Keep my unsaved draft")
            model.text = "Another draft"
            try Data("Outside edit".utf8).write(to: folder.root.appendingPathComponent("Idea.md"))
            #expect(!model.resolveDraft(.save))
            #expect(model.text == "Another draft")
            #expect(model.resolveDraft(.discard))
            #expect(!model.dirty)
            model.reloadDisk()
            #expect(model.text == "Outside edit")
        }
    }

    @Test func liveFolderRejectsOverlapsWithTheExistingLibraryEvenWhenNoDraftExists() async throws {
        try await fixture { model, _, libraryURL, _ in
            #expect(throws: (any Error).self) { try model.open(libraryURL.deletingLastPathComponent(), avoiding: libraryURL) }
            #expect(throws: (any Error).self) { try model.open(libraryURL.deletingLastPathComponent().deletingLastPathComponent(), avoiding: libraryURL) }
            #expect(model.folder?.root.lastPathComponent == "markdown")
        }
    }

    @Test func nativeLiveFolderWindowRendersSourceAndPreview() async throws {
        try await fixture { model, _, libraryURL, _ in
            _ = NSApplication.shared
            model.select("Idea.md")
            let defaultsName = "DeltosLivePresentation-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set("Light", forKey: "folioTheme")
            let store = NotesStore(storage: LibraryStorage(url: libraryURL), preferences: defaults)
            let host = NSHostingView(rootView: LiveMarkdownView(model: model).environmentObject(store).defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 1240)
            for _ in 0..<50 where window.delegate == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(window.delegate?.windowShouldClose?(window) == true)
            func webView(in view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.compactMap { webView(in: $0) }.first
            }
            let web = try #require(webView(in: host))
            var rendered = ""
            for _ in 0..<100 {
                rendered = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
                if rendered.contains("Ordinary files") { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(rendered.contains("Ordinary files"))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let preview = try await web.takeSnapshot(configuration: nil)
            let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            var rect = web.convert(web.bounds, to: host)
            if host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            preview.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            try png.write(to: package.appendingPathComponent("dist/Deltos-live-markdown-preview.png"))
        }
    }

    private func fixture(_ action: @MainActor (LiveMarkdownStore, LiveMarkdownFolder, URL, Data) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/library.json")
        try LibraryStorage(url: local).save(.starter())
        let original = try Data(contentsOf: local)
        let files = root.appendingPathComponent("markdown")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let folder = try LiveMarkdownFolder(root: files)
        try folder.createDirectory(at: "Work")
        try folder.createNote(at: "Work/Research.md", text: "# Research\n\nA real Markdown file in a subfolder.")
        try folder.createNote(at: "Idea.md", text: "# Live Markdown\n\nOrdinary files, separate from your library.")
        let model = LiveMarkdownStore()
        try model.open(files, avoiding: local)
        try await action(model, folder, local, original)
    }
}
