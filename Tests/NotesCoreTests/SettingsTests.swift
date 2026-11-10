import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@MainActor
struct SettingsTests {
    @Test func settingsSearchMatchesControlsAndDoesNotInventUnsupportedOptions() {
        #expect(SettingsSection.matching("spelling") == [.editor])
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
        let view = NativePageView(html: "Words", resources: nil, size: 17, family: .system, dracula: false,
                                  actions: actions, onChange: { _ in }, onFiles: { _ in }, onError: { Issue.record("\($0)") })
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
        defaults.set(true, forKey: "composeSpellChecking")
        for _ in 0..<50 where !editor.isContinuousSpellCheckingEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.isContinuousSpellCheckingEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
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
}
