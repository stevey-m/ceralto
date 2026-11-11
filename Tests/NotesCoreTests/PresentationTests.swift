import AppKit
import NotesCore
import SwiftUI
import Testing
import WebKit
@testable import Folio

@Suite(.serialized)
@MainActor
struct PresentationTests {
    @Test(arguments: [FolioTheme.light, .dark, .dracula], [720.0, 1240.0])
    func libraryWorkspaceRespectsTheNativeTitlebar(theme: FolioTheme, width: Double) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DeltosTitlebar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(theme.rawValue, forKey: "folioTheme")
        let notebook = Notebook(name: "Ideas")
        let notes = ["First thought", "Second thought"].map {
            Note(notebookID: notebook.id, title: $0, body: "Synthetic sample text.", format: .formatted)
        }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: notes))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.openNote(notes[0].id)
        let host = NSHostingView(rootView: LibraryWindowContent()
            .environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let probes = descendants(host).compactMap { $0 as? ThemeWindowStyle.Probe }
        let workspace = try #require(probes.max { $0.bounds.height < $1.bounds.height })
        let rect = workspace.convert(workspace.bounds, to: nil)
        #expect(window.contentLayoutRect.maxY < host.bounds.maxY)
        #expect(rect.maxY <= window.contentLayoutRect.maxY,
                "The workspace headers and tabs must start below the native titlebar.")
        #expect(rect.width >= 720 && rect.height >= 520)
        #expect(store.workspace.tabs.count == 1)
        #expect(store.library.notes == notes)
        let frame = try #require(host.superview)
        let toolbar = try #require(window.toolbar)
        let required = ["sidebar-options", "note-list-title", "note-list-options", "note-new",
                        "note-formatting", "note-attachments", "note-export", "note-actions", "library-search"]
        func toolbarRect(_ identifier: String) throws -> NSRect {
            let item = try #require(toolbar.visibleItems?.first { $0.itemIdentifier.rawValue == identifier },
                                    "\(identifier) must be visible, not relegated to toolbar overflow.")
            let view = try #require(item.view)
            return view.convert(view.bounds, to: nil)
        }
        let controlRects = try required.map(toolbarRect)
        let centers = controlRects.map(\.midY)
        #expect(try #require(centers.max()) - #require(centers.min()) <= 4,
                "Folder, list, editing and search controls must share one native toolbar row.")
        for control in controlRects {
            #expect(control.minY >= window.contentLayoutRect.maxY)
            #expect(control.minX >= 0 && control.maxX <= width,
                    "Every primary control must fit, including at the 720-point minimum width.")
        }
        let widths = PaneWidths(available: width)
        let notesStart = widths.notebooks + PaneWidths.divider
        let notesEnd = notesStart + widths.notes
        let title = try toolbarRect("note-list-title")
        #expect(title.minX >= notesStart && title.maxX <= notesEnd)
        #expect(try toolbarRect("note-new").maxX <= notesEnd + 8,
                "New note belongs above the note-list column, not above the editor.")
        #expect(try toolbarRect("note-formatting").minX >= notesEnd)
        #expect(abs(try toolbarRect("library-search").maxX - (width - 8)) <= 8,
                "Search and sharing must remain at the right edge of the toolbar.")
        let searchFields = descendants(frame).compactMap { $0 as? NSTextField }
            .filter { $0.placeholderString == "Search" }
        #expect(searchFields.isEmpty == (widths.document < 560),
                "Narrow windows must show the search button instead of a clipped search field.")
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent("dist/Ceralto-toolbar-\(theme.rawValue.lowercased())-\(Int(width))-preview.png"))
        for key in ["showNotebookPane", "showNoteListPane"] {
            defaults.set(false, forKey: key)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            for identifier in ["sidebar-options", "note-new", "note-formatting", "note-export", "library-search"] {
                let control = try toolbarRect(identifier)
                #expect(control.minX >= 0 && control.maxX <= width)
            }
            #expect(store.library.notes == notes)
        }
    }

    @Test func nestedNotebookSidebarRendersAlongsideScopedNotesWithoutChangingLibrary() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DeltosNotebookTree-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Dracula", forKey: "folioTheme")
        let root = Notebook(name: "Study")
        let child = Notebook(name: "Study/Networks")
        let nested = Notebook(name: "Study/Networks/Practice")
        let sibling = Notebook(name: "Study/Cloud")
        let unrelated = Notebook(name: "Personal")
        let note = Note(notebookID: child.id, title: "Routing fundamentals",
                        body: "## Keep the hierarchy\n\nYour subfolders belong in the notebook tree.", format: .formatted)
        let exercise = Note(notebookID: nested.id, title: "Practice lab")
        let other = Note(notebookID: sibling.id, title: "Cloud notes")
        let library = Library(notebooks: [root, child, nested, sibling, unrelated], notes: [note, exercise, other])
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(library)
        let store = NotesStore(storage: storage, preferences: defaults)
        store.scope = .folder("Study/Networks", [child.id, nested.id])
        store.selectedNoteID = note.id
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        defer { window.contentView = nil }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.mainFolderScope == .folder("Study/Networks", [child.id, nested.id]))
        #expect(Set(store.outlineNotes.map(\.id)) == Set([note.id, exercise.id]))
        #expect(store.library == library)
        #expect(store.errorMessage == nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent("dist/Deltos-notebook-tree-preview.png"))
    }

    @Test func workflowPanelsRenderWithSyntheticNotesAndRealTemplatePacks() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioWorkflowPresentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Light", forKey: "folioTheme")
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Work/Release")
        let note = Note(notebookID: notebook.id, title: "A thoughtful next release",
                        body: "# Next steps\n\n- [ ] Review the new chapter\n- [x] Capture the original idea\n- [ ] Share the project notes",
                        tags: ["review"])
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        let tasks = try NoteTasks.find(in: store.library)
        #expect(tasks.filter { !$0.isComplete }.count == 2)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let destination = package.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func preview<V: View>(_ view: V, size: NSSize, name: String) async throws {
            let host = NSHostingView(rootView: view.environmentObject(store).defaultAppStorage(defaults))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            defer { window.contentView = nil }
            host.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == size.width)
            #expect(store.errorMessage == nil)
            if name == "Folio-tasks-preview.png" {
                func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap(descendants)
                }
                let search = try #require(descendants(host).compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString == "Search tasks, notes and notebooks" })
                let rect = search.convert(search.bounds, to: host)
                let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
                #expect(top <= 130, "Task controls must stay near the header, leaving the space for tasks.")
                #expect(rect.width >= 300)
                let segments = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }.first)
                let segmentRect = segments.convert(segments.bounds, to: host)
                #expect(segmentRect.minX >= 10 && segmentRect.maxX <= host.bounds.width - 10,
                        "All task filters must fit without clipping.")
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent(name))
        }
        try await preview(TaskOverview(), size: NSSize(width: 820, height: 560), name: "Folio-tasks-preview.png")
        try await preview(TemplateChooser(), size: NSSize(width: 760, height: 540), name: "Folio-templates-preview.png")
        try await preview(SettingsView(section: .shortcuts), size: NSSize(width: 900, height: 680),
                          name: "Folio-shortcuts-preview.png")
        let plugin = directory.appendingPathComponent("sample-obsidian-plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"id":"sample-workflow","name":"Sample workflow (inspection only)","version":"1.0","minAppVersion":"1.0"}"#.utf8)
            .write(to: plugin.appendingPathComponent("manifest.json"))
        store.inspectPluginFolder(plugin)
        let packFolder = store.extensionsDirectory.appendingPathComponent("meeting-notes")
        try FileManager.default.createDirectory(at: store.extensionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.appendingPathComponent("Examples/Extensions/meeting-notes"),
                                        to: packFolder)
        store.reloadExtensions()
        try await preview(SettingsView(section: .extensions), size: NSSize(width: 1040, height: 900),
                          name: "Folio-extensions-preview.png")
        store.setFeature(.tasks, enabled: false)
        try await preview(SettingsView(section: .features), size: NSSize(width: 900, height: 680),
                          name: "Folio-features-preview.png")
        try await preview(SettingsView(section: .sync), size: NSSize(width: 1040, height: 900),
                          name: "Folio-cloud-folders-preview.png")
        let backups = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backups) }
        let manager = try #require(store.backupManager)
        try manager.connect(backups)
        await manager.backup()
        #expect(manager.backups.count == 1)
        try await preview(SettingsView(section: .files), size: NSSize(width: 1100, height: 1050),
                          name: "Deltos-backup-settings-preview.png")
    }

    @Test func composedPageKeepsItsSpaceAndProducesASyntheticPreview() async throws {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = LibraryStorage(url: temporary.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Personal")
        let topic = Notebook(name: "Personal/Ideas")
        let work = Notebook(name: "Work")
        let note = Note(notebookID: topic.id, title: "A place for your next idea",
            body: "## Less noise. More thought.\n\nA quiet page for the things worth keeping. Write naturally, collect what matters, and find your way back.\n\n**Your words. Your files. Your pace.**\n\n- Capture the thought before it disappears\n\n- Give it a home when you are ready\n\n- Take your library with you",
            tags: ["ideas"], format: .formatted)
        let other = Note(notebookID: work.id, title: "Something worth remembering",
                         body: "## Keep the idea in view\n\nThe best tools get out of the way.\n\nRead a reference while writing your next thought. Your original stays unchanged.\n\n- Keep things simple\n- Make room for the details\n- Build on what works")
        try storage.save(Library(notebooks: [notebook, topic, work], notes: [note, other]))
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
        // Keep the fixture offscreen so a small CI display cannot constrain its width.
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> PageTextView? {
            if let text = view as? PageTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let page = try #require(editor(in: host))
        #expect(host.bounds.width == 1240)
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

        let smart = SmartFolder(name: "Ideas to revisit", query: "tag:ideas")
        try store.saveSmartFolder(smart)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(store.visibleNotes.map(\.id) == [note.id])
        #expect(editor(in: host) === page, "Selecting a smart folder must not rebuild its open writing editor.")
        let smartBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: smartBitmap)
        let smartPNG = try #require(smartBitmap.representation(using: .png, properties: [:]))
        try smartPNG.write(to: destination.appendingPathComponent("Folio-smart-folders-preview.png"))

        let smartSheet = NSHostingView(rootView: SmartFolderSheet(draft: smart)
            .environmentObject(store).defaultAppStorage(defaults))
        let smartWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        smartWindow.contentView = smartSheet
        defer { smartWindow.contentView = nil }
        smartSheet.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
        try await Task.sleep(for: .milliseconds(150))
        smartSheet.layoutSubtreeIfNeeded()
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        #expect(fields(in: smartSheet).contains { $0.stringValue == smart.name })
        #expect(fields(in: smartSheet).contains { $0.stringValue == smart.query })
        let sheetBitmap = try #require(smartSheet.bitmapImageRepForCachingDisplay(in: smartSheet.bounds))
        smartSheet.cacheDisplay(in: smartSheet.bounds, to: sheetBitmap)
        let sheetPNG = try #require(sheetBitmap.representation(using: .png, properties: [:]))
        try sheetPNG.write(to: destination.appendingPathComponent("Folio-smart-folder-sheet-preview.png"))

        store.openNoteInNewTab(other.id)
        store.openNote(note.id)
        store.showReference(other.id)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        #expect(editor(in: host) === page, "Opening a reference must not rebuild the writing editor.")
        #expect(page.frame.width >= 200)
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { webView(in: $0) }.first
        }
        for _ in 0..<100 where webView(in: host) == nil {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        #expect(store.referenceNote?.id == other.id)
        let reference = try #require(webView(in: host))
        var referenceText = ""
        for _ in 0..<50 {
            referenceText = try await reference.evaluateJavaScript("document.body.innerText") as? String ?? ""
            if referenceText.contains("Keep the idea in view") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(referenceText.contains("Keep the idea in view"))
        #expect(reference.bounds.width >= 200)
        let referenceImage = try await reference.takeSnapshot(configuration: nil)
        let referenceData = try #require(referenceImage.tiffRepresentation)
        let referenceBitmap = try #require(NSBitmapImageRep(data: referenceData))
        let referencePNG = try #require(referenceBitmap.representation(using: .png, properties: [:]))
        try referencePNG.write(to: destination.appendingPathComponent("Folio-reference-preview.png"))
        let workspaceBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: workspaceBitmap)
        let workspacePNG = try #require(workspaceBitmap.representation(using: .png, properties: [:]))
        try workspacePNG.write(to: destination.appendingPathComponent("Folio-workspace-preview.png"))

        let palette = NSHostingView(rootView: CommandPalette(onSelect: { _ in }).environmentObject(store).defaultAppStorage(defaults))
        let paletteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.contentView = palette
        defer { paletteWindow.contentView = nil }
        palette.frame = NSRect(x: 0, y: 0, width: 580, height: 500)
        try await Task.sleep(for: .milliseconds(150))
        palette.layoutSubtreeIfNeeded()
        let paletteBitmap = try #require(palette.bitmapImageRepForCachingDisplay(in: palette.bounds))
        palette.cacheDisplay(in: palette.bounds, to: paletteBitmap)
        let palettePNG = try #require(paletteBitmap.representation(using: .png, properties: [:]))
        try palettePNG.write(to: destination.appendingPathComponent("Folio-command-palette-preview.png"))
    }
}
