import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@Suite(.serialized)
@MainActor
struct GlobalAppearanceTests {
    @Test func importedPacksUpdateTheRealWorkspaceNativeDialogsAndEditorsWithoutLosingEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let application = NSApplication.shared
        let original = application.appearance
        let appearance = ApplicationAppearance(preferences: fixture.defaults)
        appearance.start()
        defer { appearance.stop(); application.appearance = original }
        let id = try #require(fixture.store.library.notes.first?.id)
        fixture.store.update(id) { $0.format = .formatted; $0.body = "Words and **bold**" }
        fixture.store.openNote(id)
        let host = NSHostingView(rootView: ContentView().environmentObject(fixture.store).defaultAppStorage(fixture.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        defer { window.contentView = nil }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if descendants(host).contains(where: { $0 is PageTextView }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(descendants(host).compactMap { $0 as? PageTextView }.first)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" edited", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(40))
        let saved = fixture.store.library
        let selection = editor.selectedRange()
        let dialog = NSOpenPanel()
        for pack in [ThemePack.presets[0], ThemePack.presets[1], ThemePack.presets[2]] {
            try fixture.store.applyThemePack(pack)
            try await waitFor {
                close(window.backgroundColor, to: NSColor(pack.backgroundColor)) &&
                    application.appearance?.name == pack.nativeAppearance?.name
            }
            host.layoutSubtreeIfNeeded()
            #expect(matches(dialog, pack.isDark ? .darkAqua : .aqua))
            #expect(editor.string.hasSuffix(" edited"))
            #expect(editor.selectedRange() == selection)
            #expect(editor.undoManager?.canUndo == true)
            #expect(close(editor.backgroundColor, to: NSColor(pack.backgroundColor)))
            #expect(close(try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor), to: NSColor(pack.selectionColor)))
            #expect(close(try #require(editor.linkTextAttributes?[.foregroundColor] as? NSColor), to: NSColor(pack.accentColor)))
            #expect(close(try #require(editor.typingAttributes[.foregroundColor] as? NSColor), to: NSColor(pack.foregroundColor)))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(fraction(bitmap, matching: NSColor(pack.backgroundColor)) > 0.25)
            #expect(fraction(bitmap, matching: NSColor(pack.sidebarColor)) > 0.05)
            #expect(fixture.store.library == saved)
        }
        fixture.defaults.set("Light", forKey: "folioTheme")
        try await waitFor { window.appearance?.name == .aqua }
        #expect(close(editor.backgroundColor, to: .textBackgroundColor))
        #expect(editor.selectedRange() == selection)
        #expect(editor.undoManager?.canUndo == true)
        #expect(fixture.store.library == saved)
    }

    @Test func applicationSelectionUpdatesExistingAndNewNativeWindowsAndDialogs() async throws {
        let application = NSApplication.shared
        let original = application.appearance
        let suite = "DeltosGlobalAppearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let appearance = ApplicationAppearance(preferences: defaults)
        defer {
            appearance.stop()
            application.appearance = original
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("Light", forKey: "folioTheme")
        appearance.start()
        appearance.start()
        #expect(application.appearance?.name == .aqua)
        let existing = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let open = NSOpenPanel()
        #expect(matches(existing, .aqua))
        #expect(matches(open, .aqua))
        defaults.set("Dracula", forKey: "folioTheme")
        try await waitFor { application.appearance?.name == .darkAqua }
        #expect(matches(existing, .darkAqua))
        #expect(matches(open, .darkAqua))
        let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        let save = NSSavePanel()
        let alert = NSAlert()
        alert.messageText = "Synthetic appearance fixture"
        #expect(matches(newWindow, .darkAqua))
        #expect(matches(save, .darkAqua))
        #expect(matches(alert.window, .darkAqua))
        defaults.set("Light", forKey: "folioTheme")
        try await waitFor { application.appearance?.name == .aqua }
        #expect(matches(existing, .aqua))
        #expect(matches(newWindow, .aqua))
        #expect(matches(save, .aqua))
        defaults.set("Dark", forKey: "folioTheme")
        try await waitFor { application.appearance?.name == .darkAqua }
        defaults.set("System", forKey: "folioTheme")
        try await waitFor { application.appearance == nil }
        #expect(existing.appearance == nil)
        #expect(newWindow.appearance == nil)
        #expect(open.appearance == nil)
        #expect(save.appearance == nil)
        defaults.set("Not a theme", forKey: "folioTheme")
        appearance.apply()
        #expect(application.appearance == nil)
    }

    @Test func independentlyPresentedSurfacesShareTheThemeAndChangeWithoutReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var note = fixture.store.library.notes[0]
        note.history = [NoteRevision(note: note)]
        let surfaces: [(String, AnyView, NSSize)] = [
            ("history", AnyView(NoteHistoryView(note: note)), NSSize(width: 760, height: 520)),
            ("mentions", AnyView(LinkedMentionsView(note: note)), NSSize(width: 564, height: 444)),
            ("link", AnyView(FormattedEditor.LinkEditorPopover(link: .constant("https://example.com"), insert: {})), NSSize(width: 320, height: 160)),
            ("search", AnyView(SearchSyntaxHelp().padding(20).frame(width: 440).folioAppearance()), NSSize(width: 440, height: 240)),
            ("capture", AnyView(QuickCaptureView()), NSSize(width: 480, height: 420))
        ]
        for (name, surface, size) in surfaces {
            fixture.defaults.set("Dracula", forKey: "folioTheme")
            let host = NSHostingView(rootView: surface.environmentObject(fixture.store).defaultAppStorage(fixture.defaults))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            defer { window.contentView = nil }
            try await waitFor { window.appearance?.name == .darkAqua }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(fraction(bitmap, matching: NSColor(FolioPalette.background)) > 0.3,
                    "\(name) must use the selected palette, not the native default surface.")
            if name == "capture" {
                let editor = try #require(descendants(host).compactMap { $0 as? SourceTextView }.first)
                #expect(close(editor.backgroundColor, to: NSColor(FolioPalette.background)))
                #expect(close(try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor),
                              to: NSColor(FolioPalette.selection)))
                window.makeFirstResponder(editor)
                editor.insertText("Synthetic capture draft", replacementRange: NSRange(location: 0, length: 0))
                #expect(fixture.defaults.string(forKey: "captureDraftBody") == "Synthetic capture draft")
                editor.setSelectedRange(NSRange(location: 4, length: 5))
            }
            for theme in [FolioTheme.light, .dark, .system, .dracula] {
                fixture.defaults.set(theme.rawValue, forKey: "folioTheme")
                try await waitFor { window.appearance?.name == theme.nativeAppearance?.name }
                if theme == .light { #expect(matches(window, .aqua)) }
                if theme == .dark || theme == .dracula { #expect(matches(window, .darkAqua)) }
            }
            if name == "capture" {
                let editor = try #require(descendants(host).compactMap { $0 as? SourceTextView }.first)
                #expect(editor.string == "Synthetic capture draft")
                #expect(editor.selectedRange() == NSRange(location: 4, length: 5))
                #expect(editor.undoManager?.canUndo == true)
            }
        }
    }

    @Test func stoppingAppearanceObservationDoesNotKeepApplyingPreferenceChanges() async throws {
        let application = NSApplication.shared
        let original = application.appearance
        let suite = "DeltosGlobalStop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let appearance = ApplicationAppearance(preferences: defaults)
        defer {
            appearance.stop()
            application.appearance = original
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("Dark", forKey: "folioTheme")
        appearance.start()
        #expect(application.appearance?.name == .darkAqua)
        appearance.stop()
        defaults.set("Light", forKey: "folioTheme")
        try await Task.sleep(for: .milliseconds(50))
        #expect(application.appearance?.name == .darkAqua)
        appearance.start()
        #expect(application.appearance?.name == .aqua)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition())
    }

    private func matches(_ window: NSWindow, _ name: NSAppearance.Name) -> Bool {
        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name
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
        guard let expected = color.usingColorSpace(bitmap.colorSpace) else { Issue.record("Missing screenshot colour profile."); return 0 }
        var matches = 0
        var total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                total += 1
                if let pixel = bitmap.colorAt(x: x, y: y),
                   abs(pixel.redComponent - expected.redComponent) < 0.015,
                   abs(pixel.greenComponent - expected.greenComponent) < 0.015,
                   abs(pixel.blueComponent - expected.blueComponent) < 0.015 { matches += 1 }
            }
        }
        return Double(matches) / Double(total)
    }

    @MainActor private struct Fixture {
        let root: URL
        let suite = "DeltosGlobalSurfaces-\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: NotesStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set("Dracula", forKey: "folioTheme")
            defaults.set("", forKey: "captureDraftBody")
            defaults.set("", forKey: "captureDraftTitle")
            let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
            try storage.save(.starter())
            store = NotesStore(storage: storage, preferences: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove appearance fixture: \(error.localizedDescription)") }
        }
    }
}
