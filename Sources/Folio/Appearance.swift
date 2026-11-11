import AppKit
import NotesCore
import SwiftUI

extension FolioTheme {
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .dracula, .custom: NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .dracula, .custom: .dark
        }
    }
}

@MainActor
final class ApplicationAppearance: NSObject {
    private let preferences: UserDefaults
    private var observing = false
    private var appliedTheme: FolioTheme?
    private var appliedPalette: ThemePack?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: UserDefaults.didChangeNotification, object: preferences)
        apply()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        observing = false
        appliedTheme = nil
        appliedPalette = nil
    }

    func apply() {
        let theme = FolioTheme(rawValue: preferences.string(forKey: "folioTheme") ?? "") ?? .system
        let palette = theme == .custom ? try? ThemePack.decode(preferences.data(forKey: "customThemePack") ?? Data()) : nil
        guard appliedTheme != theme || appliedPalette != palette else { return }
        NSApplication.shared.appearance = palette?.nativeAppearance ?? theme.nativeAppearance
        appliedTheme = theme
        appliedPalette = palette
    }

    @objc nonisolated private func preferencesChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.apply() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
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
    @ThemeColors private var palette
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @AppStorage("folioDraculaAccent") private var draculaAccent = "Theme default"
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let selected = FolioTheme(rawValue: theme) ?? .system
        let tint = selected == .custom ? palette?.accentColor ?? Color.accentColor :
            FolioPalette.accent(selected, accent: accent, draculaAccent: draculaAccent,
                                       scheme: selected.colorScheme ?? systemScheme)
        content
            .preferredColorScheme(palette?.colorScheme ?? selected.colorScheme)
            .tint(tint)
            .accentColor(tint)
            .foregroundStyle(palette?.foregroundColor ?? Color.primary,
                             palette?.mutedColor ?? Color.secondary,
                             palette?.mutedColor.opacity(0.8) ?? Color.secondary.opacity(0.7))
            .backgroundStyle(palette?.backgroundColor ?? Color(nsColor: .windowBackgroundColor))
            .background(palette?.backgroundColor ?? Color(nsColor: .windowBackgroundColor))
            .scrollContentBackground(palette != nil ? .hidden : .automatic)
            .toolbarBackground(palette?.backgroundColor ?? Color.clear, for: .windowToolbar)
            .toolbarBackground(palette != nil ? .visible : .automatic, for: .windowToolbar)
            .background(ThemeWindowStyle(theme: selected, palette: palette))
    }
}

extension View {
    func folioAppearance() -> some View { modifier(FolioAppearance()) }
    func folioSidebar() -> some View { modifier(FolioSidebar()) }
    func folioListRow(selected: Bool) -> some View { modifier(FolioListRow(selected: selected)) }
}

private struct FolioListRow: ViewModifier {
    @ThemeColors private var palette
    let selected: Bool
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioDraculaAccent") private var accent = "Theme default"
    func body(content: Content) -> some View {
        let tint = theme == FolioTheme.custom.rawValue ? palette?.accentColor ?? Color.accentColor :
            FolioAccent(rawValue: accent)?.color(for: .dark) ?? FolioPalette.purple
        content
            .listRowBackground(selected ? palette?.selectionColor : nil)
            .listItemTint(palette != nil ? .fixed(tint) : nil)
    }
}

private struct FolioSidebar: ViewModifier {
    @ThemeColors private var palette
    func body(content: Content) -> some View {
        content.background(palette?.sidebarColor ?? Color(nsColor: .windowBackgroundColor))
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

    @MainActor static func style(_ editor: NSTextView, dracula: Bool, palette: ThemePack? = nil) {
        let palette = palette ?? (dracula ? .dracula : nil)
        editor.selectedTextAttributes = palette.map {
            [.backgroundColor: NSColor($0.selectionColor), .foregroundColor: NSColor($0.foregroundColor)]
        } ?? [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        editor.backgroundColor = palette.map { NSColor($0.backgroundColor) } ?? .textBackgroundColor
    }

    @MainActor static func styleRichText(_ editor: NSTextView, dracula: Bool, accent: Color = purple, palette: ThemePack? = nil) {
        guard let palette = palette ?? (dracula ? .dracula : nil), let storage = editor.textStorage else { return }
        func colors(_ attributes: [NSAttributedString.Key: Any]) -> (NSColor, Bool) {
            let block = attributes[.folioBlock] as? String
            let code = attributes[.folioCode] as? Bool == true || block == FormattedBlock.Style.code.rawValue
            let color = code ? palette.codeColor
                : block == FormattedBlock.Style.heading1.rawValue || block == FormattedBlock.Style.heading2.rawValue ? accent
                : block == FormattedBlock.Style.quote.rawValue ? palette.mutedColor : palette.foregroundColor
            return (NSColor(color), code)
        }
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let (color, code) = colors(attributes)
            storage.addAttribute(.foregroundColor, value: color, range: range)
            if code { storage.addAttribute(.backgroundColor, value: NSColor(palette.sidebarColor), range: range) }
        }
        var typing = editor.typingAttributes
        let (color, code) = colors(typing)
        typing[.foregroundColor] = color
        if code { typing[.backgroundColor] = NSColor(palette.sidebarColor) }
        editor.typingAttributes = typing
    }
}

struct ThemeWindowStyle: NSViewRepresentable {
    let theme: FolioTheme
    let palette: ThemePack?

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.theme = theme
        view.palette = palette
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.theme = theme
        view.palette = palette
        view.apply()
    }

    @MainActor final class Probe: NSView {
        var theme = FolioTheme.system
        var palette: ThemePack?
        private weak var styledWindow: NSWindow?
        private var originalBackground: NSColor?
        private var originalTransparent: Bool?
        private var appliedTheme: FolioTheme?
        private var appliedPalette: ThemePack?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window else { return }
            guard styledWindow !== window || appliedTheme != theme || appliedPalette != palette else { return }
            if styledWindow !== window {
                styledWindow = window
                originalBackground = window.backgroundColor
                originalTransparent = window.titlebarAppearsTransparent
            }
            window.appearance = palette?.nativeAppearance ?? theme.nativeAppearance
            window.backgroundColor = palette.map { NSColor($0.backgroundColor) } ?? originalBackground ?? .windowBackgroundColor
            window.titlebarAppearsTransparent = palette != nil || (originalTransparent ?? false)
            appliedTheme = theme
            appliedPalette = palette
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

struct TextSizeButtons: View {
    @AppStorage("editorFontSize") private var fontSize = 15.0

    var body: some View {
        Button("Larger Text") { fontSize = min(fontSize + 1, 28) }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(fontSize >= 28)
        Button("Smaller Text") { fontSize = max(fontSize - 1, 11) }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= 11)
    }
}

struct AppearanceSettings: View {
    @AppStorage("showNoteDetails") private var showNoteDetails = false
    @AppStorage("alwaysShowTabs") private var alwaysShowTabs = false
    @AppStorage("noteListFontSize") private var noteListFontSize = 13.0
    @AppStorage("noteListSpacing") private var noteListSpacing = NoteListSpacing.comfortable.rawValue
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
                ForEach(FolioTheme.allCases.filter { $0 != .custom || theme == FolioTheme.custom.rawValue }, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            ThemePackControls()
            Picker("Accent colour", selection: theme == FolioTheme.dracula.rawValue ? $draculaAccent : $accent) {
                if theme == FolioTheme.dracula.rawValue { Text("Theme default (Dracula purple)").tag("Theme default") }
                ForEach(FolioAccent.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .disabled(theme == FolioTheme.custom.rawValue)
            Picker("Editor and preview font", selection: $readingFont) {
                ForEach(ReadingFont.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            HStack {
                Text("Text size")
                Slider(value: $fontSize, in: 11...28, step: 1)
                Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 45)
            }
            HStack {
                Text("Note list text size")
                Slider(value: $noteListFontSize, in: 11...20, step: 1)
                Text("\(Int(noteListFontSize)) pt").monospacedDigit().frame(width: 45)
            }
            Picker("Note list spacing", selection: $noteListSpacing) {
                ForEach(NoteListSpacing.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Images in notes", selection: $thumbnailSize) {
                Text("Fit note width (Recommended)").tag(0)
                Text("Tiny (80 px)").tag(80)
                Text("Small (180 px)").tag(180)
                Text("Medium (300 px)").tag(300)
            }
            Toggle("Full-width preview text", isOn: $fullWidth)
            Toggle("Show notebook, tags and status details above/below the note", isOn: $showNoteDetails)
            Toggle("Always show the document tab bar", isOn: $alwaysShowTabs)
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
            Text("Your selection applies throughout Deltos, including windows, sheets, popovers and native dialogs. System follows your Mac; Light and Dark stay fixed. Dracula is optional and has its own accent choice. Native macOS menus and controls use the matching light or dark appearance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
