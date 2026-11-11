import AppKit
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

@propertyWrapper
struct ThemeColors: DynamicProperty {
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("customThemePack") private var data = Data()

    var wrappedValue: ThemePack? {
        if theme == FolioTheme.dracula.rawValue { return .dracula }
        guard theme == FolioTheme.custom.rawValue else { return nil }
        // Settings and NotesStore surface invalid saved packs without overwriting them.
        return try? ThemePack.decode(data)
    }
}

extension ThemePack {
    private func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var backgroundColor: Color { color(background) }
    var sidebarColor: Color { color(sidebar) }
    var selectionColor: Color { color(selection) }
    var foregroundColor: Color { color(foreground) }
    var accentColor: Color { color(accent) }
    var mutedColor: Color { color(muted) }
    var codeColor: Color { color(code) }
    var nativeAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

struct ThemePackControls: View {
    @EnvironmentObject private var store: NotesStore
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("customThemePack") private var data = Data()
    @ViewState private var error: String?

    private var saved: ThemePack? { try? ThemePack.decode(data) }

    var body: some View {
        LabeledContent("Theme pack", value: theme == FolioTheme.custom.rawValue ? saved?.name ?? "Invalid saved theme" : "Not active")
        Menu("Choose Native Theme Pack") {
            ForEach(ThemePack.presets, id: \.id) { pack in
                Button(pack.name) {
                    do { try store.applyThemePack(pack); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        HStack {
            Button("Import Theme...") { importTheme() }
            Button("Export Theme Pack...") { exportTheme() }
                .disabled(theme != FolioTheme.custom.rawValue || saved == nil)
        }
        Text("Import a .deltostheme or JSON colour pack. These native palettes apply across Ceralto; they do not install Joplin .jpl plugins, CodeMirror themes or arbitrary CSS. Native macOS controls use the pack's light or dark appearance.")
            .font(.caption).foregroundStyle(.secondary)
        if theme == FolioTheme.custom.rawValue, saved == nil {
            Label("The saved theme pack cannot be read. Its data is preserved; choose a built-in appearance or import a valid pack.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.title = "Import Ceralto Theme"
        panel.message = "Choose a Ceralto JSON colour pack, not a Joplin plugin or CSS file. The current theme is unchanged if import fails."
        panel.allowedContentTypes = [.json, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do { try store.importThemePack(from: url); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func exportTheme() {
        guard let saved else { error = "Choose a valid theme pack before exporting."; return }
        let panel = NSSavePanel()
        panel.title = "Export Ceralto Theme"
        panel.nameFieldStringValue = saved.id + ".deltostheme"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do { try saved.encoded().write(to: url, options: .atomic); error = nil }
        catch { self.error = "Theme export failed: \(error.localizedDescription)" }
    }
}
