import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@MainActor
struct SettingsTests {
    @Test func invalidThemeImportLeavesCurrentPaletteAndNotesUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeltosThemeImport-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage, preferences: defaults)
        let file = root.appendingPathComponent("theme.deltostheme")
        let pack = try #require(ThemePack.presets.first { $0.id == "nord" })
        try pack.encoded().write(to: file)
        try store.importThemePack(from: file)
        #expect(defaults.string(forKey: "folioTheme") == FolioTheme.custom.rawValue)
        let originalData = try #require(defaults.data(forKey: "customThemePack"))
        let originalLibrary = store.library
        let persisted = try Data(contentsOf: storage.url)
        try Data("joplin.plugins.register({})".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.importThemePack(from: file) }
        #expect(defaults.data(forKey: "customThemePack") == originalData)
        #expect(store.library == originalLibrary)
        let restarted = NotesStore(storage: storage, preferences: defaults)
        #expect(restarted.errorMessage == nil)
        let restoredPack = try ThemePack.decode(try #require(defaults.data(forKey: "customThemePack")))
        #expect(restoredPack == pack)
        let after = try Data(contentsOf: storage.url)
        #expect(after == persisted)
        defaults.set(Data("corrupt theme".utf8), forKey: "customThemePack")
        let corrupt = NotesStore(storage: storage, preferences: defaults)
        #expect(corrupt.errorMessage != nil)
        #expect(defaults.data(forKey: "customThemePack") == Data("corrupt theme".utf8))
    }

    @Test func settingsSearchMatchesControlsAndDoesNotInventUnsupportedOptions() {
        #expect(SettingsSection.matching("spelling") == [.editor])
        #expect(SettingsSection.matching("line numbers") == [.editor])
        #expect(SettingsSection.matching("sorting ascending") == [.general])
        #expect(SettingsSection.matching("accent gold") == [.appearance])
        #expect(SettingsSection.matching("backup restore") == [.files])
        #expect(SettingsSection.matching("offline ipad") == [.sync])
        #expect(Set(SettingsSection.matching("plugins")) == Set([.extensions, .features]))
        #expect(SettingsSection.matching("obsidian inspect") == [.extensions])
        #expect(SettingsSection.matching("optional tools") == [.features])
        #expect(SettingsSection.matching("hotkeys") == [.shortcuts])
        #expect(SettingsSection.matching("   ").count == SettingsSection.allCases.count)
        #expect(SettingsSection.matching("missing-feature").isEmpty)
    }

    @Test func defaultFormatPersistsAndAffectsOnlyNewNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioSettings-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let store = NotesStore(storage: storage, preferences: preferences)
        store.createNote()
        let composed = try #require(store.selectedNote)
        #expect(composed.contentFormat == .formatted)
        preferences.set(NoteFormat.markdown.rawValue, forKey: "defaultNoteFormat")
        store.createNote()
        #expect(store.selectedNote?.contentFormat == .markdown)
        #expect(store.library.notes.first { $0.id == composed.id } == composed)
        let restarted = NotesStore(storage: storage, preferences: preferences)
        restarted.createNote()
        #expect(restarted.selectedNote?.contentFormat == .markdown)
        preferences.set(NoteFormat.formatted.rawValue, forKey: "defaultNoteFormat")
        restarted.createMarkdownNote()
        #expect(restarted.selectedNote?.contentFormat == .markdown, "The explicit source-note command overrides the default.")
    }

    @Test func spellCheckingPreferenceUpdatesTheHostedNativeEditor() async throws {
        let suite = "FolioSpelling-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "composeSpellChecking")
        let actions = FormattingActions()
        var saved = "Words"
        let view = NativePageView(html: saved, resources: nil, size: 17, family: .system, dracula: false,
                                  actions: actions, onChange: { saved = $0 }, onError: { Issue.record("\($0)") },
                                  currentSource: { saved })
        let host = NSHostingView(rootView: view.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 where actions.editor == nil {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let editor = try #require(actions.editor)
        #expect(!editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.pairDelimiters && !editor.markdownShortcuts)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" more", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(20))
        defaults.set(true, forKey: "composeSpellChecking")
        defaults.set(true, forKey: "composeMarkdownShortcuts")
        defaults.set(true, forKey: "editorPairDelimiters")
        defaults.set(720, forKey: "writingColumnWidth")
        for _ in 0..<50 where !editor.isContinuousSpellCheckingEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(editor.pairDelimiters && editor.markdownShortcuts)
        #expect(editor.textContainerInset.width > 28)
        #expect(editor.string == "Words more")
        #expect(actions.editor === editor)
        #expect(editor.undoManager?.canUndo == true)
    }

    @Test func sourcePreferencesUpdateWithoutResettingNativeUndoAndExcludeQuickCapture() async throws {
        let suite = "DeltosSourcePreferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = "One\nTwo\n"
        let view = SourceEditor(text: Binding(get: { saved }, set: { saved = $0 }),
                                family: .monospace, size: 15, dracula: false, currentSource: { saved })
        let host = NSHostingView(rootView: view.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 450)
        host.layoutSubtreeIfNeeded()
        func source(in view: NSView) -> SourceTextView? {
            if let editor = view as? SourceTextView { return editor }
            return view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        let editor = try #require(source(in: host))
        #expect(!editor.pairDelimiters)
        #expect(editor.tabStyle == .native)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("Edit", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(30))
        defaults.set(true, forKey: "editorPairDelimiters")
        defaults.set(true, forKey: "sourceLineNumbers")
        defaults.set(SourceTabStyle.fourSpaces.rawValue, forKey: "sourceTabStyle")
        defaults.set(720, forKey: "writingColumnWidth")
        for _ in 0..<50 where !editor.pairDelimiters {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let scroll = try #require(editor.enclosingScrollView)
        let ruler = try #require(scroll.verticalRulerView as? SourceLineRuler)
        #expect(scroll.rulersVisible)
        #expect(ruler.lineStarts == [0, 4, 8])
        #expect(editor.textContainerInset.width > 100)
        #expect(editor.string == "One\nTwo\nEdit")
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(saved == "One\nTwo\n")
        #expect(ruler.lineStarts == [0, 4, 8])
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertTab(nil)
        #expect(saved.hasSuffix("\n    "))
        editor.insertText("\n", replacementRange: editor.selectedRange())
        #expect(ruler.lineStarts.count == 4)
        editor.setFrameSize(NSSize(width: 500, height: editor.frame.height))
        #expect(editor.textContainerInset.width == 20)
        let captureHost = NSHostingView(rootView: SourceEditor(text: .constant("Capture"), family: .system, size: 15,
            dracula: false, currentSource: { "Capture" }, usesWritingPreferences: false).defaultAppStorage(defaults))
        captureHost.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        captureHost.layoutSubtreeIfNeeded()
        let capture = try #require(source(in: captureHost))
        #expect(!capture.pairDelimiters)
        #expect(capture.tabStyle == .native)
        #expect(capture.enclosingScrollView?.rulersVisible == false)
        #expect(capture.textContainerInset.width == 20)
    }

    @Test(arguments: SettingsSection.allCases)
    func settingsSectionsRenderInANativeWindow(section: SettingsSection) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioSettingsPresentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Light", forKey: "folioTheme")
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: defaults)
        let host = NSHostingView(rootView: SettingsView(section: section).environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == 900)
        #expect(store.errorMessage == nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if section == .general {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let destination = package.appendingPathComponent("dist")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("Folio-settings-preview.png"))
        }
    }

    @Test(arguments: ["System", "Light", "Dark", "Dracula", "nord", "github-light"])
    func closeButtonStaysVisibleInCompactSettingsAndClosesOnlyItsOwnWindow(theme: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DeltosSettingsClose-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let pack = ThemePack.presets.first(where: { $0.id == theme }) {
            defaults.set(try pack.encoded(), forKey: "customThemePack")
            defaults.set(FolioTheme.custom.rawValue, forKey: "folioTheme")
        } else { defaults.set(theme, forKey: "folioTheme") }
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")), preferences: defaults)
        let controller = SettingsWindowController()
        controller.show(store: store, preferences: defaults, section: .files)
        let window = try #require(controller.window)
        let host = try #require(window.contentViewController?.view)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        window.setContentSize(NSSize(width: 720, height: 480))
        defer { controller.close(); other.close() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if buttons(in: host).contains(where: { $0.accessibilityIdentifier() == "deltos-close-settings" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let button = try #require(buttons(in: host).first { $0.accessibilityIdentifier() == "deltos-close-settings" })
        let frame = button.convert(button.bounds, to: host)
        #expect(host.bounds.contains(frame))
        #expect(frame.width >= 90 && frame.height >= 20)
        #expect(!button.isHiddenOrHasHiddenAncestor)
        #expect(button.isEnabled)
        #expect(button.keyEquivalent == "\u{1b}")
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == NSSize(width: 720, height: 480))
        #expect(window.contentMaxSize.width > 1_200)
        #expect(window.contentMaxSize.height > 900)
        // AppKit clamps visible windows to the display's usable area.
        let screen = try #require(window.screen)
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        let expandedSize = NSSize(width: min(1_200, available.width), height: min(900, available.height))
        #expect(expandedSize.width > 720 && expandedSize.height > 480)
        window.setContentSize(expandedSize)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.size == expandedSize)
        #expect(host.bounds.contains(button.convert(button.bounds, to: host)))
        window.setContentSize(NSSize(width: 720, height: 480))
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.size == NSSize(width: 720, height: 480))
        #expect(host.bounds.contains(button.convert(button.bounds, to: host)))
        button.performClick(nil)
        #expect(!window.isVisible)
        #expect(other.isVisible)
        controller.show(store: store, preferences: defaults)
        #expect(controller.window === window)
        #expect(window.isVisible)
        let reopenedSize = NSSize(width: min(1_100, available.width), height: min(800, available.height))
        window.setContentSize(reopenedSize)
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.contentLayoutRect.size == reopenedSize)
        #expect(window.styleMask.contains(.resizable))
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

}
