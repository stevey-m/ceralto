import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

struct NoteBrowserTests {
    @Test func dateGroupsUseCalendarDaysAcrossDaylightSavingAndKeepPinnedNotesFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        func date(_ month: Int, _ day: Int, _ hour: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: 30)))
        }
        let notebook = UUID()
        let dates = try [date(11, 3), date(11, 2), date(11, 1), date(10, 28), date(10, 10), date(9, 10)]
        let notes = dates.map { Note(notebookID: notebook, title: "Dated", createdAt: $0, updatedAt: $0) }
        let pinned = Note(notebookID: notebook, title: "Pinned", isPinned: true,
                          createdAt: dates[5], updatedAt: dates[5])
        let groups = NoteDateSection.grouping(notes + [pinned], ordering: NoteOrdering(),
                                              now: try date(11, 2, 12), calendar: calendar)
        #expect(Array(groups.prefix(6).map(\.title)) == ["Pinned", "Future", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
        #expect(groups.flatMap(\.notes).map(\.id) == [pinned.id] + notes.map(\.id))
        let ascending = NoteDateSection.grouping(notes + [pinned], ordering: NoteOrdering(ascending: true),
                                                 now: try date(11, 2, 12), calendar: calendar)
        #expect(ascending.flatMap(\.notes).map(\.id) == [pinned.id] + notes.reversed().map(\.id))
        #expect(NoteDateSection.grouping([], ordering: NoteOrdering()).isEmpty)
    }

    @Test func dateGroupingUsesCreatedDateOnlyWhenSortingByCreation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let note = Note(notebookID: UUID(), title: "Alpha", createdAt: yesterday, updatedAt: now)
        let updated = NoteDateSection.grouping([note], ordering: NoteOrdering(), now: now, calendar: calendar)
        let created = NoteDateSection.grouping([note], ordering: NoteOrdering(field: .created), now: now, calendar: calendar)
        #expect(updated.first?.title == "Today")
        #expect(created.first?.title == "Yesterday")
        #expect(updated.first?.notes == [note] && created.first?.notes == [note])
    }

    @Test func gallerySelectionSupportsCommandShiftAndFiltersStaleSelections() {
        let ids = (0..<5).map { _ in UUID() }
        let stale = UUID()
        #expect(GallerySelection.selecting(ids[2], in: ids, current: [ids[0]], anchor: ids[0],
                                          extending: true, toggling: false) == Set(ids[0...2]))
        #expect(GallerySelection.selecting(ids[4], in: ids, current: [ids[0]], anchor: ids[3],
                                          extending: true, toggling: true) == [ids[0], ids[3], ids[4]])
        #expect(GallerySelection.selecting(ids[0], in: ids, current: [ids[0], ids[2], stale], anchor: ids[0],
                                          extending: false, toggling: true) == [ids[2]])
        #expect(GallerySelection.selecting(ids[4], in: ids, current: [ids[0]], anchor: stale,
                                          extending: true, toggling: false) == [ids[4]])
    }

    @Test func attachmentIndexHandlesMarkdownHtmlDuplicatesAndMissingOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("my image.png")
        let pdf = root.appendingPathComponent("report.pdf")
        try Data("image fixture".utf8).write(to: image)
        try Data("PDF fixture".utf8).write(to: pdf)
        let note = Note(notebookID: UUID(), body: """
        ![Photo](my%20image.png)
        [Repeated image](my%20image.png#detail)
        [Report](report.pdf)
        [Web](https://example.com/report.pdf)
        ![Remote](https://example.com/image.png)
        [Anchor](#heading)
        ```
        ![Not an attachment](code.png)
        ```
        """, importedSourceURL: root.appendingPathComponent("note.md"), importedRootURL: root)
        let files = try Attachments.references(in: note)
        #expect(files.map(\.kind) == [.image, .pdf])
        #expect(files.map(\.name) == ["Photo", "Report"])
        #expect(try files[0].resolvedURL() == image.resolvingSymlinksInPath())
        var html = note
        html.format = .html
        html.body = "<p><img src=\"my%20image.png\" alt=\"Photo\"><a href=\"report.pdf\">Report</a></p>"
        #expect(try Attachments.references(in: html).map(\.name) == ["Photo", "Report"])
        try FileManager.default.removeItem(at: pdf)
        #expect(throws: (any Error).self) { try files[1].resolvedURL() }
    }

    @Test func attachmentIndexBlocksTraversalAndRechecksSymlinkTargetsBeforeOpening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("Outside".utf8).write(to: outside)
        var note = Note(notebookID: UUID(), body: "[Outside](../outside.txt)",
                        importedSourceURL: resources.appendingPathComponent("note.md"), importedRootURL: resources)
        #expect(throws: NoteWorkflowError.self) { try Attachments.references(in: note) }
        let inside = resources.appendingPathComponent("inside.txt")
        try Data("Inside".utf8).write(to: inside)
        note.body = "[Inside](inside.txt)"
        let file = try #require(Attachments.references(in: note).first)
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
        #expect(throws: NoteWorkflowError.self) { try file.resolvedURL() }
        #expect(throws: NoteWorkflowError.self) { try Attachments.references(in: note) }
    }
}

@MainActor
struct NoteBrowserPresentationTests {
    @Test func attachmentThumbnailsAreBoundedAndOriginalFilesRemainUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosAttachments-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 400).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 140).fill()
        NSGraphicsContext.restoreGraphicsState()
        let original = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = root.appendingPathComponent("landscape.png")
        try original.write(to: image)
        try Data("Ideas for the next project.".utf8).write(to: root.appendingPathComponent("brief.txt"))
        let notebook = Notebook(name: "Ideas")
        let note = Note(notebookID: notebook.id, title: "Project inspiration",
                        body: "![Landscape](landscape.png)\n[Project brief](brief.txt)",
                        importedSourceURL: root.appendingPathComponent("note.md"), importedRootURL: root)
        let files = try Attachments.references(in: note)
        let file = try #require(files.first)
        let generated = try AttachmentThumbnail.thumbnail(file)
        let data = try #require(generated)
        let thumbnail = try #require(NSBitmapImageRep(data: data))
        #expect(thumbnail.pixelsWide == 400 && thumbnail.pixelsHigh == 200)
        #expect(try Data(contentsOf: image) == original)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        let host = NSHostingView(rootView: AttachmentBrowser(notes: [note], scopeTitle: "Ideas")
            .environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let rendered = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)
        let png = try #require(rendered.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent("dist/Deltos-attachments-preview.png"))
        #expect(store.errorMessage == nil)
    }

    @Test func galleryAndGroupedListSwitchWithoutChangingTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosNoteBrowser-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "noteListGallery")
        defaults.set(true, forKey: "noteListGroupDates")
        defaults.set(480.0, forKey: "noteListPaneWidth")
        let notebook = Notebook(name: "Ideas")
        let notes = ["Project ideas", "Meeting notes", "Weekend reading", "Travel plans"].map {
            Note(notebookID: notebook.id, title: $0, body: "A place for thoughts and useful details.", format: .formatted)
        }
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: notes))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.scope = .all
        store.openNote(notes[0].id)
        let saved = try Data(contentsOf: storage.url)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: package.appendingPathComponent("dist/Deltos-note-browser-preview.png"))
        defaults.set(false, forKey: "noteListGallery")
        defaults.set("Spacious", forKey: "noteListSpacing")
        defaults.set(17.0, forKey: "noteListFontSize")
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(store.selectedNoteID == notes[0].id)
        #expect(store.library.notes == notes)
        #expect(try Data(contentsOf: storage.url) == saved)
        #expect(store.outlineNotes.count == notes.count)
        #expect(store.errorMessage == nil)
    }
}
