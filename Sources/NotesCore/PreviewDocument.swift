import Foundation
import SwiftSoup
import cmark_gfm
import cmark_gfm_extensions

public enum FolioTheme: String, CaseIterable, Sendable {
    case system = "System", light = "Light", dark = "Dark", dracula = "Dracula", custom = "Theme pack"

    public var cssColorScheme: String {
        switch self {
        case .system: "light dark"
        case .light: "light"
        case .dark, .dracula, .custom: "dark"
        }
    }
}

public enum FolioAccent: String, CaseIterable, Sendable {
    case gold = "Gold", blue = "Blue", purple = "Purple", green = "Green", rose = "Rose"

    public var lightHex: String {
        switch self {
        case .gold: "#946200"
        case .blue: "#0069c2"
        case .purple: "#7040bd"
        case .green: "#197345"
        case .rose: "#b33362"
        }
    }

    public var darkHex: String {
        switch self {
        case .gold: "#efbe50"
        case .blue: "#70baff"
        case .purple: "#c4a0ff"
        case .green: "#6bd49a"
        case .rose: "#ff92b7"
        }
    }
}

public enum ReadingFont: String, CaseIterable, Sendable {
    case system = "System", monospace = "Monospace", serif = "Serif"

    public var css: String {
        switch self {
        case .system: "-apple-system, BlinkMacSystemFont, sans-serif"
        case .monospace: "'SF Mono', Menlo, Monaco, monospace"
        case .serif: "Georgia, 'Times New Roman', serif"
        }
    }
}

public struct PreviewOptions: Equatable, Sendable {
    public var theme: FolioTheme = .system
    public var accent: FolioAccent = .gold
    public var draculaAccent: FolioAccent?
    public var palette: ThemePack?
    public var font: ReadingFont = .system
    public var fontSize: Double = 15
    public var thumbnailSize: Int = 0
    public var fullWidth: Bool = false

    public init() {}
}

public struct ImportedResources: Equatable, Sendable {
    public let source: URL
    public let root: URL

    public init(source: URL, root: URL) {
        self.source = source.standardizedFileURL.resolvingSymlinksInPath()
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func localURL(for reference: String) -> URL? {
        guard let url = URL(string: reference, relativeTo: source.deletingLastPathComponent())?.absoluteURL,
              url.isFileURL, isContained(url) else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func isContained(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.path + "/")
    }

    public func previewURL(for reference: String) -> URL? {
        guard let local = localURL(for: reference) else { return nil }
        var components = URLComponents()
        components.scheme = "folio-resource"
        components.host = "local"
        components.path = "/" + local.path.dropFirst(root.path.count + 1)
        components.fragment = URL(string: reference)?.fragment
        return components.url
    }

    public func fileURL(for previewURL: URL) -> URL? {
        guard previewURL.scheme == "folio-resource", previewURL.host == "local" else { return nil }
        let path = previewURL.path
        let candidate = root.appendingPathComponent(String(path.dropFirst()))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(candidate) else { return nil }
        return candidate
    }
}

public enum PreviewDocument {
    public static func markdownHTML(_ source: String, hardLineBreaks: Bool = false) throws -> String {
        try renderMarkdown(source, hardLineBreaks: hardLineBreaks) { _ in }
    }

    static func renderMarkdown(_ source: String, hardLineBreaks: Bool,
                               prepare: (UnsafeMutablePointer<cmark_node>) throws -> Void) throws -> String {
        // The extension registry is process-global. Serializing registration and rendering
        // keeps concurrent preview requests from racing cmark's registry.
        registryLock.lock()
        defer { registryLock.unlock() }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES) else {
            throw JoplinImportError.invalid("The Markdown parser could not be initialized.")
        }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            guard let ext = cmark_find_syntax_extension(name) else {
                throw JoplinImportError.invalid("The Markdown '\(name)' extension is unavailable.")
            }
            cmark_parser_attach_syntax_extension(parser, ext)
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else {
            throw JoplinImportError.invalid("Markdown could not be parsed.")
        }
        defer { cmark_node_free(document) }
        try prepare(document)
        let renderOptions = CMARK_OPT_UNSAFE | (hardLineBreaks ? CMARK_OPT_HARDBREAKS : 0)
        guard let rendered = cmark_render_html(document, renderOptions, cmark_parser_get_syntax_extensions(parser)) else {
            throw JoplinImportError.invalid("Markdown could not be rendered.")
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private static let registryLock = NSLock()

    public static func html(source: String, format: NoteFormat, resources: ImportedResources?,
                            options: PreviewOptions = PreviewOptions(), noteLinks: [String: UUID] = [:],
                            editableIDs: Set<String> = []) throws -> String {
        try options.palette?.validate()
        let input = format.usesHTML ? source : try markdownHTML(source, hardLineBreaks: format == .markdown)
        let linked = try NoteLinks.linkedBody(sanitizedBody(input, resources: resources, editableIDs: editableIDs), targets: noteLinks)
        let document = try SwiftSoup.parseBodyFragment(linked)
        for table in try document.select("table") {
            if try !["none", "presentation"].contains(table.attr("role")) {
                try table.wrap("<div class=\"folio-table-scroll\"></div>")
            }
        }
        let safe = try document.body()?.html() ?? ""
        let thumbnail = min(max(options.thumbnailSize, 64), 400)
        let imageSizing = options.thumbnailSize == 0
            ? "width: 100% !important; max-width: 100%; max-height: none;"
            : "width: auto !important; max-width: min(100%, \(thumbnail)px); max-height: \(thumbnail)px;"
        let fontSize = min(max(options.fontSize, 11), 32)
        let dracula = options.theme == .dracula
        let palette = options.palette
        let scheme = palette.map { $0.isDark ? "dark" : "light" } ?? options.theme.cssColorScheme
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src folio-resource:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: \(scheme);
          --bg: \(palette?.background ?? (dracula ? "#282a36" : "Canvas")); --fg: \(palette?.foreground ?? (dracula ? "#f8f8f2" : "CanvasText"));
          --muted: \(palette?.muted ?? (dracula ? "#a5a9c5" : "GrayText"));
          --accent: \(palette?.accent ?? (dracula ? options.draculaAccent?.darkHex ?? "#bd93f9" : options.theme == .dark ? options.accent.darkHex : options.accent.lightHex));
          --line: \(palette?.selection ?? (dracula ? "#44475a" : "color-mix(in srgb, CanvasText 18%, Canvas)"));
          --code: \(palette?.sidebar ?? (dracula ? "#21222c" : "color-mix(in srgb, CanvasText 5%, Canvas)"));
          --green: \(palette?.code ?? (dracula ? "#50fa7b" : "#168143")); --pink: \(dracula ? "#ff79c6" : "#ae287b"); }
        \(options.theme == .system ? "@media (prefers-color-scheme: dark) { :root { --accent: \(options.accent.darkHex); } }" : "")
        * { box-sizing: border-box; }
        body { margin: 0; padding: 28px 32px 64px; background: var(--bg); color: var(--fg);
          font: \(fontSize)px/1.5 \(options.font.css); overflow-wrap: anywhere; }
        main { max-width: none; margin: 0 auto; }
        main > * { max-width: \(options.fullWidth ? "none" : "860px"); margin-inline: auto; }
        main > p:has(img.folio-thumbnail), main > figure { max-width: none; }
        main > .folio-table-scroll { max-width: none; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.3; margin: 1.4em 0 .6em; color: var(--accent); }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; border-bottom: 1px solid var(--line); padding-bottom: .3em; }
        h3 { font-size: 1.2em; } p { margin: .8em 0; } a { color: var(--accent); }
        strong,em { color: inherit; }
        pre { background: var(--code); padding: 18px; border: 1px solid var(--line); border-radius: 8px; overflow-x: auto; }
        code { font-family: 'SF Mono', Menlo, monospace; background: var(--code); border-radius: 4px; padding: .12em .3em; }
        pre code { padding: 0; } blockquote { margin: 1em 0; border-left: 3px solid var(--accent);
          padding: .2em 1em; background: var(--code); border-radius: 0 6px 6px 0; color: var(--muted); }
        ul,ol { padding-left: 1.8em; } li { margin: .3em 0; } li > p { margin: .35em 0; }
        .folio-table-scroll { overflow-x: auto; margin: .6em 0 .65em; }
        table { border-collapse: collapse; text-align: left; margin: 0; }
        td,th { border: 1px solid var(--line); padding: .5em 1em; color: var(--fg); }
        th { background: var(--code); border-bottom-width: 2px; }
        td[align=center],th[align=center] { text-align: center; }
        td[align=right],th[align=right] { text-align: right; }
        table tr:nth-child(even) { background: var(--code); }
        table[role=none],table[role=presentation] { width: 100%; }
        table:is([role=none],[role=presentation]) > :is(thead,tbody,tfoot) > tr { background: transparent; }
        table:is([role=none],[role=presentation]) > :is(thead,tbody,tfoot) > tr > :is(td,th) {
          border: 0; padding: 0; background: transparent; }
        hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }
        img.folio-thumbnail { display: inline-block; \(imageSizing)
          height: auto !important; object-fit: contain;
          border: 1px solid var(--line); border-radius: 6px; cursor: zoom-in; vertical-align: middle; margin: 6px 0; }
        img.folio-thumbnail:hover, img.folio-thumbnail:focus { outline: 2px solid var(--accent); }
        .folio-image-placeholder { display: inline-block; padding: 8px; color: var(--muted);
          border: 1px dashed var(--line); border-radius: 6px; font-size: .85em; }
        details { padding: 10px 14px; background: var(--code); border-radius: 6px; margin: 1em 0; }
        summary { cursor: pointer; color: var(--accent); } input[type=checkbox] { accent-color: var(--accent); }
        </style></head><body><main>\(safe)</main></body></html>
        """
    }

    public static func sanitizedBody(_ html: String, resources: ImportedResources?,
                                     editableIDs: Set<String> = []) throws -> String {
        let document = try SwiftSoup.parse(html)
        // Remove active content before cleaning, rather than retaining script text.
        try document.select("script,style,iframe,object,embed,form,base,link,meta,svg,math").remove()
        for image in try document.select("img") {
            if let width = Double(try image.attr("width")), let height = Double(try image.attr("height")),
               (0...1).contains(width), (0...1).contains(height) {
                try image.remove()
            }
        }
        for table in try document.select("table[role]") {
            let role = try table.attr("role").lowercased()
            if ["none", "presentation"].contains(role) { try table.attr("role", role) }
            else { try table.removeAttr("role") }
        }
        for element in try document.select("[style]") {
            let safeStyle = FormattedPage.safeInlineStyle(try element.attr("style"))
            if !safeStyle.isEmpty {
                try element.attr("style", safeStyle)
            } else {
                try element.removeAttr("style")
            }
        }
        let whitelist = try Whitelist.relaxed()
            .addTags("input", "details", "summary", "figure", "figcaption", "del", "s", "kbd", "hr", "span")
            .addAttributes(":all", "style")
            .addAttributes("input", "type", "checked", "disabled")
            .addAttributes("a", "id", "name")
            .addAttributes("h1", "id").addAttributes("h2", "id").addAttributes("h3", "id")
            .addAttributes("td", "align").addAttributes("th", "align")
            .addAttributes("table", "role")
            .removeProtocols("a", "href", "ftp")
        if !editableIDs.isEmpty { try whitelist.addAttributes("span", "data-ceralto-edit") }
        // URLs are explicitly resolved and allowlisted below, including relative paths.
        try whitelist.removeProtocols("img", "src", "http", "https")
        try whitelist.removeProtocols("a", "href", "http", "https", "mailto")
        let cleaned = try SwiftSoup.clean(try document.body()?.html() ?? "", whitelist)
        let body = try SwiftSoup.parseBodyFragment(cleaned ?? "")
        for marker in try body.select("[data-ceralto-edit]") {
            if !editableIDs.contains(try marker.attr("data-ceralto-edit")) {
                try marker.removeAttr("data-ceralto-edit")
            }
        }
        for image in try body.select("img") {
            let source = try image.attr("src")
            let alt = try image.attr("alt")
            try image.removeAttr("width").removeAttr("height").removeAttr("style")
            if let url = resources?.previewURL(for: source) {
                try image.attr("src", url.absoluteString).attr("class", "folio-thumbnail")
                    .attr("tabindex", "0").attr("role", "button")
                    .attr("title", "Click to expand original image")
                    .attr("aria-label", alt.isEmpty ? "Expand image" : "Expand \(alt)")
            } else {
                let placeholder = try image.before("<span class=\"folio-image-placeholder\"></span>")
                // before() returns the image; select its preceding element to avoid HTML interpolation.
                if let span = try placeholder.previousElementSibling() {
                    try span.text(alt.isEmpty ? "Image unavailable (external or missing resource)" : "Image: \(alt) (external or missing resource)")
                }
                try image.remove()
            }
        }
        for link in try body.select("a[href]") {
            let reference = try link.attr("href")
            if reference.hasPrefix("#") { continue }
            if let url = URL(string: reference), url.scheme == "folio-note",
               let host = url.host, UUID(uuidString: host) != nil,
               url.user == nil, url.password == nil, url.port == nil,
               url.path.isEmpty, url.query == nil {
                continue
            } else if let local = resources?.previewURL(for: reference) {
                try link.attr("href", local.absoluteString)
            } else if let url = URL(string: reference),
                      ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                try link.attr("rel", "noreferrer noopener")
            } else {
                try link.removeAttr("href")
            }
        }
        for input in try body.select("input") {
            guard try input.attr("type").lowercased() == "checkbox" else { try input.remove(); continue }
            try input.attr("disabled", "disabled")
        }
        return try body.body()?.html() ?? ""
    }
}
