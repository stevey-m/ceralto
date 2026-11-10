import NotesCore
import SwiftUI

extension FolioTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .dracula: .dark
        }
    }
}

extension FolioAccent {
    func color(for scheme: ColorScheme) -> Color {
        let hex = scheme == .dark ? darkHex : lightHex
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}

private struct FolioAppearance: ViewModifier {
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let selected = FolioTheme(rawValue: theme) ?? .system
        content
            .preferredColorScheme(selected.colorScheme)
            .tint((FolioAccent(rawValue: accent) ?? .gold).color(for: selected.colorScheme ?? systemScheme))
    }
}

extension View {
    func folioAppearance() -> some View { modifier(FolioAppearance()) }
}

enum FolioPalette {
    static let background = Color(red: 40 / 255, green: 42 / 255, blue: 54 / 255)
    static let sidebar = Color(red: 33 / 255, green: 34 / 255, blue: 44 / 255)
    static let selection = Color(red: 68 / 255, green: 71 / 255, blue: 90 / 255)
    static let foreground = Color(red: 248 / 255, green: 248 / 255, blue: 242 / 255)
    static let purple = Color(red: 189 / 255, green: 147 / 255, blue: 249 / 255)
}

extension ReadingFont {
    func swiftUIFont(size: Double) -> Font {
        switch self {
        case .system: .system(size: size)
        case .monospace: .system(size: size, design: .monospaced)
        case .serif: .system(size: size, design: .serif)
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @AppStorage("readingFont") private var readingFont = ReadingFont.system.rawValue
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("imageDisplayWidth") private var thumbnailSize = 0
    @AppStorage("fullWidthNotes") private var fullWidth = false
    @AppStorage("notebookPaneWidth") private var notebookWidth = 220.0
    @AppStorage("noteListPaneWidth") private var noteListWidth = 250.0
    @AppStorage("showNotebookPane") private var showNotebooks = true
    @AppStorage("showNoteListPane") private var showNotes = true
    @AppStorage("readingEditorMode") private var editorMode = "Preview"

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(FolioTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Accent colour", selection: $accent) {
                ForEach(FolioAccent.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Editor and preview font", selection: $readingFont) {
                ForEach(ReadingFont.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            HStack {
                Text("Text size")
                Slider(value: $fontSize, in: 11...28, step: 1)
                Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 45)
            }
            Picker("Images in notes", selection: $thumbnailSize) {
                Text("Fit note width (Recommended)").tag(0)
                Text("Tiny (80 px)").tag(80)
                Text("Small (180 px)").tag(180)
                Text("Medium (300 px)").tag(300)
            }
            Toggle("Full-width preview text", isOn: $fullWidth)
            Toggle("Show main folders", isOn: $showNotebooks)
            Toggle("Show subtopics and notes", isOn: $showNotes)
            Text("Images fill the available note width without changing the original. Click to open in the document area; pinch to zoom, scroll to pan, and use Back to note to return.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset Reading Layout") {
                notebookWidth = 220
                noteListWidth = 250
                showNotebooks = true
                showNotes = true
                editorMode = "Preview"
                thumbnailSize = 0
            }
            Text("System follows your Mac's appearance. Light and Dark stay fixed. Dracula remains available as an alternative palette.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
