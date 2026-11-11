import SwiftUI

struct BuiltInFeaturesSettings: View {
    @EnvironmentObject private var store: NotesStore

    var body: some View {
        Section("Optional Ceralto tools") {
            Text("Switch off tools you do not use. Your notes, tasks, templates and workflow preferences are kept. These are native Ceralto features, not imported Obsidian core plugins.")
                .foregroundStyle(.secondary)
            ForEach(BuiltInFeature.allCases) { feature in
                Toggle(isOn: Binding(get: { store.featureEnabled(feature) },
                                     set: { store.setFeature(feature, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feature.name)
                        Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!store.isLoaded || store.isReadOnly || !store.extensionConfigurationAvailable)
            }
            Text("Daily notes can still use an enabled template when the chooser is off. Turning off Task overview does not remove Markdown checkboxes or prevent editing them in a note. Search, recovery and other essential notebook functions remain available.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ExtensionConfigurationRecovery()
    }
}

struct ExtensionConfigurationRecovery: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var confirmingReset = false

    var body: some View {
        if let message = store.extensionConfigurationError {
            Section("Extension settings need attention") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
                Button("Retry Loading Settings", action: store.reloadExtensionConfiguration)
                Button("Reset Extension Settings...") { confirmingReset = true }
                    .disabled(!store.isLoaded || store.isReadOnly)
            }
            .confirmationDialog("Reset extension settings?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive, action: store.resetExtensionConfiguration)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This discards the unreadable configuration, forgets registered plugin folders, and enables built-in tools and template packs. It does not change notes or files in any extension folder.")
            }
        }
    }
}

struct CommunityExtensionsSettings: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.openWindow) private var openWindow
    @ViewState private var query = ""
    @ViewState private var confirmingDisable = false
    @ViewState private var removing: PluginInspection?

    private func matches(_ text: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
            .allSatisfy { text.localizedStandardContains(String($0)) }
    }

    var body: some View {
        Section("Manage community extensions") {
            TextField("Search registered extensions", text: $query)
            Text("Enable Ceralto template packs or inspect a local Joplin/Obsidian plugin folder. External plugins cannot run: Ceralto reads manifest metadata only, without loading code or making network requests.")
                .foregroundStyle(.secondary)
            Button("Inspect Joplin or Obsidian Folder...", action: store.choosePluginFolder)
                .disabled(!store.isLoaded || store.isReadOnly || !store.extensionConfigurationAvailable)
            Button("Recheck Registered Folders", action: store.refreshPluginInspections)
            Text("Select an extracted folder containing manifest.json. No .jpl packages, URL installs or updates yet. Original plugin files are never modified or removed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ExtensionConfigurationRecovery()
        Section("Ceralto template packs") {
            Button("Open Extensions Folder", action: store.revealExtensions)
            Button("Reload Template Packs", action: store.reloadExtensions)
            if store.extensions.isEmpty {
                Text("No template packs installed. Place a folder containing extension.json in Extensions, then reload.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.extensions.filter { matches($0.name + " " + $0.id) }) { pack in
                Toggle(isOn: Binding(
                    get: { store.activeTemplatePacks.contains(where: { $0.id == pack.id }) },
                    set: { store.setTemplatePack(pack.id, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pack.name).font(.headline)
                        Text("Supported · Data-only template API 1 · \(pack.templates.count) templates")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(pack.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .disabled(!store.isLoaded || store.isReadOnly || !store.extensionConfigurationAvailable)
            }
            Button("Disable All Community Template Packs...") { confirmingDisable = true }
                .disabled(store.activeTemplatePacks.isEmpty || !store.isLoaded || store.isReadOnly ||
                          !store.extensionConfigurationAvailable)
            Button("Choose a Template...") {
                openWindow(id: "library")
                store.perform(.templates)
            }.disabled(FolioCommand.templates.unavailableReason(in: store) != nil)
            Text("Disabling a pack removes it from the chooser and template menus. Existing notes are untouched. A daily note using that pack needs another enabled template for new dates; existing dated notes still open. To uninstall, move the pack out of the Extensions folder and reload.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Joplin & Obsidian folders — inspection only") {
            if store.pluginInspections.isEmpty {
                Text("No plugin folders registered. Registration does not install or enable executable code.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.pluginInspections.filter {
                matches(($0.metadata.map { "\($0.ecosystem.rawValue) \($0.name) \($0.id)" } ?? "") +
                        " " + $0.location.folder.lastPathComponent)
            }) { inspection in
                VStack(alignment: .leading, spacing: 8) {
                    if let metadata = inspection.metadata {
                        HStack(alignment: .firstTextBaseline) {
                            Text(metadata.name).font(.headline)
                            Text(metadata.version).foregroundStyle(.secondary)
                        }
                        Text("\(metadata.ecosystem.rawValue) · \(metadata.id)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Label("Cannot run — \(metadata.ecosystem.rawValue) runtime/API is not implemented",
                              systemImage: "nosign").foregroundStyle(.orange)
                        Text("Declares \(metadata.ecosystem.rawValue) \(metadata.minimumHostVersion) or newer. Reading a manifest is not a compatibility test.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(inspection.location.folder.lastPathComponent).font(.headline)
                        Label(inspection.error ?? "Metadata unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(inspection.location.folder.path)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("Forget Registration...") { removing = inspection }
                        .disabled(!store.isLoaded || store.isReadOnly || !store.extensionConfigurationAvailable)
                }.padding(.vertical, 6)
            }
        }
        .confirmationDialog("Forget this plugin folder?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Forget Registration", role: .destructive) {
                if let removing { store.forgetPlugin(removing.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Only Ceralto's registration is removed. No files in the original plugin folder or your notes will be deleted.")
        }
        .confirmationDialog("Disable all community template packs?", isPresented: $confirmingDisable,
                            titleVisibility: .visible) {
            Button("Disable Packs", role: .destructive, action: store.disableAllTemplatePacks)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notes and pack files are kept. Built-in templates remain available. You can enable individual packs again here.")
        }
    }
}
