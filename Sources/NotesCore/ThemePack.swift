import Foundation

public struct ThemePack: Codable, Equatable, Sendable {
    public var version = 1
    public var id: String
    public var name: String
    public var isDark: Bool
    public var background: String
    public var sidebar: String
    public var selection: String
    public var foreground: String
    public var accent: String
    public var muted: String
    public var code: String

    public static let maximumBytes = 32 * 1_024

    public func validate() throws {
        guard version == 1, !id.isEmpty, id.utf8.count <= 80,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NoteWorkflowError("Invalid theme identity or unsupported theme format.")
        }
        for color in [background, sidebar, selection, foreground, accent, muted, code] {
            guard color.count == 7, color.first == "#", UInt32(color.dropFirst(), radix: 16) != nil else {
                throw NoteWorkflowError("Theme colours must be six-digit hexadecimal values such as #282a36. CSS, scripts and URLs are not supported.")
            }
        }
        let lighter = max(Self.luminance(background), Self.luminance(foreground))
        let darker = min(Self.luminance(background), Self.luminance(foreground))
        guard (lighter + 0.05) / (darker + 0.05) >= 4.5 else {
            throw NoteWorkflowError("The theme's text and background need a contrast ratio of at least 4.5:1.")
        }
    }

    public static func decode(_ data: Data) throws -> ThemePack {
        guard data.count <= maximumBytes else { throw NoteWorkflowError("Theme packs are limited to 32 KiB.") }
        let keys: Set<String> = ["version", "id", "name", "isDark", "background", "sidebar", "selection", "foreground", "accent", "muted", "code"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else {
            throw NoteWorkflowError("Choose a Deltos JSON theme pack, not a Joplin plugin, CSS file or script.")
        }
        let result = try JSONDecoder().decode(ThemePack.self, from: data)
        try result.validate()
        return result
    }

    public static func load(from url: URL) throws -> ThemePack {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= maximumBytes else {
            throw NoteWorkflowError("Choose a regular Deltos theme file no larger than 32 KiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func luminance(_ hex: String) -> Double {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return 0 }
        func linear(_ component: UInt32) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((value >> 16) & 255) + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
    }

    public static let dracula = ThemePack(id: "dracula", name: "Dracula", isDark: true,
        background: "#282a36", sidebar: "#21222c", selection: "#44475a", foreground: "#f8f8f2",
        accent: "#bd93f9", muted: "#a5a9c5", code: "#50fa7b")

    public static let presets: [ThemePack] = [
        ThemePack(id: "github-dark", name: "GitHub Dark", isDark: true,
            background: "#0d1117", sidebar: "#161b22", selection: "#264f78", foreground: "#e6edf3",
            accent: "#58a6ff", muted: "#8b949e", code: "#7ee787"),
        ThemePack(id: "github-light", name: "GitHub Light", isDark: false,
            background: "#ffffff", sidebar: "#f6f8fa", selection: "#ddf4ff", foreground: "#1f2328",
            accent: "#0969da", muted: "#656d76", code: "#1a7f37"),
        ThemePack(id: "nord", name: "Nord", isDark: true,
            background: "#2e3440", sidebar: "#242933", selection: "#434c5e", foreground: "#eceff4",
            accent: "#88c0d0", muted: "#a6afbf", code: "#a3be8c"),
        ThemePack(id: "one-dark", name: "One Dark", isDark: true,
            background: "#282c34", sidebar: "#21252b", selection: "#3e4451", foreground: "#abb2bf",
            accent: "#61afef", muted: "#8d96a8", code: "#98c379"),
        ThemePack(id: "solarized-dark", name: "Solarized Dark", isDark: true,
            background: "#002b36", sidebar: "#073642", selection: "#164c56", foreground: "#93a1a1",
            accent: "#268bd2", muted: "#839496", code: "#859900"),
        ThemePack(id: "solarized-light", name: "Solarized Light", isDark: false,
            background: "#fdf6e3", sidebar: "#eee8d5", selection: "#d6ceba", foreground: "#586e75",
            accent: "#268bd2", muted: "#657b83", code: "#859900"),
        ThemePack(id: "monokai", name: "Monokai", isDark: true,
            background: "#272822", sidebar: "#20211c", selection: "#49483e", foreground: "#f8f8f2",
            accent: "#ae81ff", muted: "#a6a69c", code: "#a6e22e")
    ]
}
