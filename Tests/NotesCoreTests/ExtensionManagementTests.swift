import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

struct PluginInspectorTests {
    @Test func identifiesBothEcosystemsWithoutExecutingOrChangingPluginFiles() throws {
        try withDirectory { root in
            for (name, manifest, ecosystem) in [
                ("joplin", #"{"id":"test.joplin","name":"Joplin sample","version":"1.0","manifest_version":1,"app_min_version":"3.0"}"#, PluginEcosystem.joplin),
                ("obsidian", #"{"id":"test-obsidian","name":"Obsidian sample","version":"2.0","minAppVersion":"1.0"}"#, .obsidian)
            ] {
                let folder = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let manifestURL = folder.appendingPathComponent("manifest.json")
                let source = Data(manifest.utf8)
                try source.write(to: manifestURL)
                let script = Data("throw new Error('Must never execute');".utf8)
                let scriptURL = folder.appendingPathComponent("main.js")
                try script.write(to: scriptURL)
                let metadata = try PluginInspector.inspect(folder)
                #expect(metadata.ecosystem == ecosystem)
                #expect(!metadata.name.isEmpty)
                let afterManifest = try Data(contentsOf: manifestURL)
                let afterScript = try Data(contentsOf: scriptURL)
                #expect(afterManifest == source)
                #expect(afterScript == script)
            }
        }
    }

    @Test func rejectsAmbiguousMalformedFutureOversizedAndLinkedManifests() throws {
        try withDirectory { root in
            let manifestURL = root.appendingPathComponent("manifest.json")
            for manifest in [
                "{}",
                "not json",
                #"{"id":"x","name":"X","version":"1","manifest_version":2,"app_min_version":"3"}"#,
                #"{"id":"x","name":"X","version":"1","manifest_version":1,"app_min_version":"3","minAppVersion":"1"}"#,
                #"{"id":"x","name":"X","version":"1","minAppVersion":""}"#,
                #"{"id":"x","name":" \n ","version":"1","minAppVersion":"1"}"#
            ] {
                try Data(manifest.utf8).write(to: manifestURL)
                #expect(throws: (any Error).self) { try PluginInspector.inspect(root) }
            }
            try Data(repeating: 32, count: 1_048_577).write(to: manifestURL)
            #expect(throws: (any Error).self) { try PluginInspector.inspect(root) }
            try FileManager.default.removeItem(at: manifestURL)
            let target = root.appendingPathComponent("real.json")
            try Data(#"{"id":"x","name":"X","version":"1","minAppVersion":"1"}"#.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: target)
            #expect(throws: (any Error).self) { try PluginInspector.inspect(root) }
            let link = root.appendingPathComponent("linked-folder")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            #expect(throws: (any Error).self) { try PluginInspector.inspect(link) }
        }
    }

    private func withDirectory(_ action: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(directory)
    }
}

@MainActor
struct ExtensionManagementTests {
    @Test func builtinSwitchesPersistGateCommandsAndKeepAllNoteData() throws {
        try withStore { store, storage, defaults in
            let before = store.library
            store.showingTasks = true
            store.showingTemplates = true
            for feature in BuiltInFeature.allCases { store.setFeature(feature, enabled: false) }
            #expect(!store.showingTasks && !store.showingTemplates)
            for command in [FolioCommand.today, .templates, .tasks] {
                #expect(command.unavailableReason(in: store)?.contains("Built-in Features") == true)
                store.perform(command)
                #expect(store.errorMessage != nil)
            }
            #expect(throws: NoteWorkflowError.self) { try store.openDailyNote() }
            #expect(!store.createFromTemplate(TemplateChoice.daily.template))
            let tasks = try NoteTasks.find(in: store.library)
            let task = try #require(tasks.first)
            store.setTask(task, complete: true)
            #expect(store.library == before)
            let saved = try storage.load()
            #expect(saved == before)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(BuiltInFeature.allCases.allSatisfy { !restarted.featureEnabled($0) })
            restarted.setFeature(.dailyNotes, enabled: true)
            #expect(FolioCommand.today.unavailableReason(in: restarted) == nil)
            try restarted.openDailyNote()
            #expect(restarted.selectedNote?.tags.contains("daily") == true)
            #expect(!restarted.featureEnabled(.templates))
        }
    }

    @Test func disabledTemplatePacksLeaveNotesAndFilesIntactAndDailyNotesHandleUnavailableTemplates() throws {
        try withStore { store, storage, defaults in
            try installPack(in: store)
            let choice = try #require(store.templateChoices.first { $0.packID == "org.test.pack" })
            defaults.set(choice.id, forKey: "dailyTemplate")
            try store.openDailyNote(on: Date(timeIntervalSince1970: 1_700_000_000))
            let dailyID = store.selectedNoteID
            let before = store.library
            store.setTemplatePack(choice.packID, enabled: false)
            #expect(store.activeTemplatePacks.isEmpty)
            #expect(!store.extensions.isEmpty)
            #expect(!store.templateChoices.contains { $0.id == choice.id })
            #expect(!store.createFromTemplate(choice.template))
            try store.openDailyNote(on: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(store.selectedNoteID == dailyID)
            #expect(throws: NoteWorkflowError.self) {
                try store.openDailyNote(on: Date(timeIntervalSince1970: 1_700_200_000))
            }
            #expect(store.library == before)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.activeTemplatePacks.isEmpty)
            #expect(restarted.extensions.count == 1)
            restarted.setTemplatePack(choice.packID, enabled: true)
            #expect(restarted.templateChoices.contains { $0.id == choice.id })
            restarted.disableAllTemplatePacks()
            #expect(restarted.activeTemplatePacks.isEmpty)
            #expect(restarted.templateChoices == TemplateChoice.builtIn)
            let saved = try storage.load()
            #expect(saved == before)
        }
    }

    @Test func registrationsPersistRejectDuplicatesReportMissingFilesAndForgetWithoutDeleting() throws {
        try withStore { store, storage, defaults in
            let folder = storage.url.deletingLastPathComponent().appendingPathComponent("sample-plugin")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            let manifest = Data(#"{"id":"test-plugin","name":"Sample plugin","version":"1","minAppVersion":"1"}"#.utf8)
            try manifest.write(to: manifestURL)
            store.inspectPluginFolder(folder)
            let registration = try #require(store.pluginInspections.first)
            #expect(registration.metadata?.ecosystem == .obsidian)
            #expect(registration.error == nil)
            store.inspectPluginFolder(folder.appendingPathComponent("."))
            #expect(store.extensionConfiguration.plugins.count == 1)
            #expect(store.errorMessage?.contains("already registered") == true)
            let restarted = NotesStore(storage: storage, preferences: defaults)
            #expect(restarted.pluginInspections.count == 1)
            try FileManager.default.removeItem(at: manifestURL)
            restarted.refreshPluginInspections()
            #expect(restarted.pluginInspections.first?.metadata == nil)
            #expect(restarted.pluginInspections.first?.error != nil)
            #expect(restarted.extensionConfiguration.plugins.count == 1)
            try manifest.write(to: manifestURL)
            restarted.refreshPluginInspections()
            #expect(restarted.pluginInspections.first?.error == nil)
            restarted.forgetPlugin(registration.id)
            #expect(restarted.pluginInspections.isEmpty)
            let after = try Data(contentsOf: manifestURL)
            #expect(after == manifest)
        }
    }

    @Test func corruptFutureAndWrongTypeSettingsArePreservedUntilExplicitReset() throws {
        try withStore { store, _, defaults in
            try installPack(in: store)
            for data in [Data("broken".utf8),
                         Data(#"{"version":2,"disabledFeatures":[],"disabledPacks":[],"plugins":[]}"#.utf8),
                         Data(#"{"version":1,"disabledFeatures":["unknown"],"disabledPacks":[],"plugins":[]}"#.utf8)] {
                defaults.set(data, forKey: ExtensionManagerConfiguration.preferenceKey)
                store.reloadExtensionConfiguration()
                #expect(!store.extensionConfigurationAvailable)
                #expect(store.extensionConfigurationError != nil)
                #expect(store.activeTemplatePacks.isEmpty)
                store.setFeature(.tasks, enabled: false)
                #expect(defaults.data(forKey: ExtensionManagerConfiguration.preferenceKey) == data)
                store.resetExtensionConfiguration()
                #expect(store.extensionConfigurationAvailable)
                #expect(store.extensionConfigurationError == nil)
                #expect(store.activeTemplatePacks.count == 1)
            }
            defaults.set("invalid type", forKey: ExtensionManagerConfiguration.preferenceKey)
            store.reloadExtensionConfiguration()
            #expect(!store.extensionConfigurationAvailable)
            #expect(defaults.string(forKey: ExtensionManagerConfiguration.preferenceKey) == "invalid type")
        }
    }

    @Test func readonlyStoreCannotChangeExtensionConfiguration() throws {
        try withStore { store, storage, defaults in
            store.setFeature(.tasks, enabled: false)
            let before = defaults.data(forKey: ExtensionManagerConfiguration.preferenceKey)
            let reader = NotesStore(storage: storage, readOnly: true, preferences: defaults)
            reader.setFeature(.tasks, enabled: true)
            reader.resetExtensionConfiguration()
            #expect(reader.errorMessage != nil)
            #expect(defaults.data(forKey: ExtensionManagerConfiguration.preferenceKey) == before)
        }
    }

    @Test func configurationRejectsDuplicateRegistrationsAndRemoteURLs() throws {
        var config = ExtensionManagerConfiguration()
        let location = PluginLocation(id: UUID(), folder: URL(fileURLWithPath: "/tmp/example-plugin"))
        config.plugins = [location, location]
        #expect(throws: ExtensionManagementError.self) { try config.validate() }
        let remote = try #require(URL(string: "https://example.com/plugin"))
        config.plugins = [PluginLocation(id: UUID(), folder: remote)]
        #expect(throws: ExtensionManagementError.self) { try config.validate() }
    }

    private func installPack(in store: NotesStore) throws {
        let folder = store.extensionsDirectory.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id":"org.test.pack","name":"Test pack","apiVersion":1,"templates":[{"id":"daily","name":"Daily","title":"{{date}}","body":"A community template","tags":[]}]}"#.utf8)
            .write(to: folder.appendingPathComponent("extension.json"))
        store.reloadExtensions()
        #expect(store.errorMessage == nil)
    }

    private func withStore(_ action: (NotesStore, LibraryStorage, UserDefaults) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "FolioExtensionManager-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        let notebook = Notebook(name: "Work")
        let note = Note(notebookID: notebook.id, title: "Keep my work", body: "- [ ] Keep this task\n")
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        try action(NotesStore(storage: storage, preferences: defaults), storage, defaults)
    }
}
