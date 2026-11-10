import AppKit
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
    @AppStorage("folioDraculaAccent") private var draculaAccent = "Theme default"
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let selected = FolioTheme(rawValue: theme) ?? .system
        let dracula = selected == .dracula
        let tint = FolioPalette.accent(selected, accent: accent, draculaAccent: draculaAccent,
                                       scheme: selected.colorScheme ?? systemScheme)
        content
            .preferredColorScheme(selected.colorScheme)
            .tint(tint)
            .accentColor(tint)
            .foregroundStyle(dracula ? FolioPalette.foreground : Color.primary,
                             dracula ? FolioPalette.muted : Color.secondary,
                             dracula ? FolioPalette.muted.opacity(0.8) : Color.secondary.opacity(0.7))
            .backgroundStyle(dracula ? FolioPalette.background : Color(nsColor: .windowBackgroundColor))
            .background(dracula ? FolioPalette.background : Color(nsColor: .windowBackgroundColor))
            .scrollContentBackground(dracula ? .hidden : .automatic)
            .toolbarBackground(dracula ? FolioPalette.background : Color.clear, for: .windowToolbar)
            .toolbarBackground(dracula ? .visible : .automatic, for: .windowToolbar)
            .background(ThemeWindowStyle(dracula: dracula))
    }
}

extension View {
    func folioAppearance() -> some View { modifier(FolioAppearance()) }
    func folioSidebar() -> some View { modifier(FolioSidebar()) }
    func folioListRow(selected: Bool) -> some View { modifier(FolioListRow(selected: selected)) }
}

private struct FolioListRow: ViewModifier {
    let selected: Bool
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioDraculaAccent") private var accent = "Theme default"
    func body(content: Content) -> some View {
        let dracula = theme == FolioTheme.dracula.rawValue
        let tint = FolioAccent(rawValue: accent)?.color(for: .dark) ?? FolioPalette.purple
        content
            .listRowBackground(dracula && selected ? FolioPalette.selection : nil)
            .listItemTint(dracula ? .fixed(tint) : nil)
    }
}

private struct FolioSidebar: ViewModifier {
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    func body(content: Content) -> some View {
        content.background(theme == FolioTheme.dracula.rawValue ? FolioPalette.sidebar : Color(nsColor: .windowBackgroundColor))
    }
}

enum FolioPalette {
    static let background = Color(red: 40 / 255, green: 42 / 255, blue: 54 / 255)
    static let sidebar = Color(red: 33 / 255, green: 34 / 255, blue: 44 / 255)
    static let selection = Color(red: 68 / 255, green: 71 / 255, blue: 90 / 255)
    static let foreground = Color(red: 248 / 255, green: 248 / 255, blue: 242 / 255)
    static let purple = Color(red: 189 / 255, green: 147 / 255, blue: 249 / 255)
    static let muted = Color(red: 165 / 255, green: 169 / 255, blue: 197 / 255)
    static let green = Color(red: 80 / 255, green: 250 / 255, blue: 123 / 255)

    static func accent(_ theme: FolioTheme, accent: String, draculaAccent: String, scheme: ColorScheme) -> Color {
        if theme == .dracula {
            return FolioAccent(rawValue: draculaAccent)?.color(for: .dark) ?? purple
        }
        return (FolioAccent(rawValue: accent) ?? .gold).color(for: scheme)
    }

    @MainActor static func style(_ editor: NSTextView, dracula: Bool) {
        editor.selectedTextAttributes = dracula
            ? [.backgroundColor: NSColor(selection), .foregroundColor: NSColor(foreground)]
            : [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        editor.backgroundColor = dracula ? NSColor(background) : .textBackgroundColor
    }

    @MainActor static func styleRichText(_ editor: NSTextView, dracula: Bool, accent: Color = purple) {
        guard dracula, let storage = editor.textStorage else { return }
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let block = attributes[.folioBlock] as? String
            let code = attributes[.folioCode] as? Bool == true || block == FormattedBlock.Style.code.rawValue
            let color = code ? green
                : block == FormattedBlock.Style.heading1.rawValue || block == FormattedBlock.Style.heading2.rawValue ? accent
                : block == FormattedBlock.Style.quote.rawValue ? muted : foreground
            storage.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            if code { storage.addAttribute(.backgroundColor, value: NSColor(sidebar), range: range) }
        }
    }
}

private struct ThemeWindowStyle: NSViewRepresentable {
    let dracula: Bool

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.dracula = dracula
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.dracula = dracula
        view.apply()
    }

    @MainActor final class Probe: NSView {
        var dracula = false
        private weak var styledWindow: NSWindow?
        private var originalBackground: NSColor?
        private var originalTransparent: Bool?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window else { return }
            if styledWindow !== window {
                styledWindow = window
                originalBackground = window.backgroundColor
                originalTransparent = window.titlebarAppearsTransparent
            }
            window.backgroundColor = dracula ? NSColor(FolioPalette.background) : originalBackground ?? .windowBackgroundColor
            window.titlebarAppearsTransparent = dracula || (originalTransparent ?? false)
        }
    }
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
    @AppStorage("folioDraculaAccent") private var draculaAccent = "Theme default"
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
            Picker("Accent colour", selection: theme == FolioTheme.dracula.rawValue ? $draculaAccent : $accent) {
                if theme == FolioTheme.dracula.rawValue { Text("Theme default (Dracula purple)").tag("Theme default") }
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
            Text("System follows your Mac's appearance. Light and Dark stay fixed. Dracula is optional, with its own accent choice: keep the original purple or choose another colour. The other themes keep their separate accent preference. macOS menus and file panels follow system dark appearance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
