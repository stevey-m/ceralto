import NotesCore
import SwiftUI

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
    @AppStorage("folioTheme") private var theme = FolioTheme.dracula.rawValue
    @AppStorage("readingFont") private var readingFont = ReadingFont.monospace.rawValue
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("imageDisplayWidth") private var thumbnailSize = 0
    @AppStorage("fullWidthNotes") private var fullWidth = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(FolioTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
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
            Toggle("Full-width note pages", isOn: $fullWidth)
            Text("Images fill the available note width without changing the original. Click to open in the document area; pinch to zoom, scroll to pan, and use Back to note to return.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset Reading Layout") {
                UserDefaults.standard.set(220.0, forKey: "notebookPaneWidth")
                UserDefaults.standard.set(250.0, forKey: "noteListPaneWidth")
                UserDefaults.standard.set(true, forKey: "showNotebookPane")
                UserDefaults.standard.set(true, forKey: "showNoteListPane")
                UserDefaults.standard.set("Preview", forKey: "readingEditorMode")
                thumbnailSize = 0
            }
            Text("Dracula is a color theme, paired here with a macOS monospaced font. Choose System or Serif if preferred.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 410)
        .preferredColorScheme(theme == FolioTheme.dracula.rawValue ? .dark : nil)
    }
}
