import AppKit
import Foundation
import NotesCore

enum BuiltInFeature: String, CaseIterable, Identifiable, Codable {
    case dailyNotes, templates, tasks

    var id: String { rawValue }
    var name: String {
        switch self {
        case .dailyNotes: "Daily notes"
        case .templates: "Template chooser"
        case .tasks: "Task overview"
        }
    }
    var detail: String {
        switch self {
        case .dailyNotes: "Create or reopen today's dated note. Configure its notebook and template in Editor."
        case .templates: "Choose a built-in or enabled community template when creating a note."
        case .tasks: "Find and complete Markdown tasks across your notebooks."
        }
    }
}

enum PluginEcosystem: String, Codable {
    case joplin = "Joplin", obsidian = "Obsidian"
}

struct PluginLocation: Codable, Equatable, Identifiable {
    let id: UUID
    let folder: URL
}

struct PluginMetadata: Equatable {
    let ecosystem: PluginEcosystem
    let id: String
    let name: String
    let version: String
    let minimumHostVersion: String
}

struct PluginInspection: Identifiable {
    let location: PluginLocation
    let metadata: PluginMetadata?
    let error: String?
    var id: UUID { location.id }
}

enum PluginInspector {
    private struct Manifest: Decodable {
        let id: String
        let name: String
        let version: String
        let manifest_version: Int?
        let app_min_version: String?
        let minAppVersion: String?
    }

    static func inspect(_ folder: URL) throws -> PluginMetadata {
        guard folder.isFileURL, folder.path.hasPrefix("/") else {
            throw ExtensionManagementError("Choose a local plugin folder.")
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExtensionManagementError("Choose an extracted plugin folder, not a package or symbolic link.")
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
              let size = manifestValues.fileSize, size > 0, size <= 1_048_576 else {
            throw ExtensionManagementError("manifest.json must be a regular file of at most 1 MB, not a symbolic link.")
        }
        let file = try FileHandle(forReadingFrom: manifestURL)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw ExtensionManagementError("The plugin manifest exceeds 1 MB.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let fields = [manifest.id, manifest.name, manifest.version]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.count <= 200 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw ExtensionManagementError("The plugin must declare a nonempty ID, name and version of at most 200 characters.")
        }
        let ecosystem: PluginEcosystem
        let minimum: String
        if manifest.manifest_version != nil, manifest.minAppVersion == nil {
            guard manifest.manifest_version == 1, let value = manifest.app_min_version else {
                throw ExtensionManagementError("This Joplin manifest version is unsupported or lacks app_min_version.")
            }
            ecosystem = .joplin
            minimum = value
        } else if manifest.manifest_version == nil, manifest.app_min_version == nil,
                  let value = manifest.minAppVersion {
            ecosystem = .obsidian
            minimum = value
        } else {
            throw ExtensionManagementError("The manifest does not unambiguously identify a Joplin or Obsidian plugin.")
        }
        guard !minimum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, minimum.count <= 100,
              !minimum.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExtensionManagementError("The plugin's minimum host version is invalid.")
        }
        return PluginMetadata(ecosystem: ecosystem, id: manifest.id, name: manifest.name,
                              version: manifest.version, minimumHostVersion: minimum)
    }
}

struct ExtensionManagerConfiguration: Codable, Equatable {
    static let preferenceKey = "extensionManager"
    var version = 1
    var disabledFeatures: Set<BuiltInFeature> = []
    var disabledPacks: Set<String> = []
    var plugins: [PluginLocation] = []

    func validate() throws {
        guard version == 1 else { throw ExtensionManagementError("The saved extension-manager version is unsupported.") }
        guard disabledPacks.count <= 1_000, disabledPacks.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              plugins.count <= 100, Set(plugins.map(\.id)).count == plugins.count,
              Set(plugins.map { $0.folder.standardizedFileURL.path }).count == plugins.count,
              plugins.allSatisfy({ $0.folder.isFileURL && $0.folder.path.hasPrefix("/") }) else {
            throw ExtensionManagementError("The saved extension-manager configuration is invalid.")
        }
    }
}

struct ExtensionManagementError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension NotesStore {
    func featureEnabled(_ feature: BuiltInFeature) -> Bool {
        !extensionConfiguration.disabledFeatures.contains(feature)
    }

    var activeTemplatePacks: [NoteExtension] {
        guard extensionConfigurationAvailable else { return [] }
        return extensions.filter { !extensionConfiguration.disabledPacks.contains($0.id) }
    }

    func setFeature(_ feature: BuiltInFeature, enabled: Bool) {
        var candidate = extensionConfiguration
        if enabled { candidate.disabledFeatures.remove(feature) }
        else { candidate.disabledFeatures.insert(feature) }
        saveExtensionConfiguration(candidate)
    }

    func setTemplatePack(_ id: String, enabled: Bool) {
        guard extensions.contains(where: { $0.id == id }) else {
            errorMessage = "Reload template packs before changing this pack."
            return
        }
        var candidate = extensionConfiguration
        if enabled { candidate.disabledPacks.remove(id) }
        else { candidate.disabledPacks.insert(id) }
        saveExtensionConfiguration(candidate)
    }

    func disableAllTemplatePacks() {
        var candidate = extensionConfiguration
        candidate.disabledPacks.formUnion(extensions.map(\.id))
        saveExtensionConfiguration(candidate)
    }

    func inspectPluginFolder(_ folder: URL) {
        do {
            _ = try PluginInspector.inspect(folder)
            let folder = folder.standardizedFileURL
            guard !extensionConfiguration.plugins.contains(where: { $0.folder.standardizedFileURL == folder }) else {
                throw ExtensionManagementError("This folder is already registered. Use Recheck to read its current manifest.")
            }
            var candidate = extensionConfiguration
            candidate.plugins.append(PluginLocation(id: UUID(), folder: folder))
            saveExtensionConfiguration(candidate)
        } catch { errorMessage = "Could not inspect the plugin: \(error.localizedDescription)" }
    }

    func forgetPlugin(_ id: UUID) {
        var candidate = extensionConfiguration
        candidate.plugins.removeAll { $0.id == id }
        saveExtensionConfiguration(candidate)
    }

    func choosePluginFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Inspect Folder"
        panel.message = "Select an extracted Joplin or Obsidian plugin folder containing manifest.json. Ceralto reads metadata only; it cannot run these plugins. No source files will be changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspectPluginFolder(url)
    }
}
