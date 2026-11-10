import Foundation
import SwiftSoup
import cmark_gfm
import cmark_gfm_extensions

public enum FolioTheme: String, CaseIterable, Sendable {
    case system = "System", dracula = "Dracula"
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
    public var theme: FolioTheme = .dracula
    public var font: ReadingFont = .monospace
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
    public static func markdownHTML(_ source: String) throws -> String {
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
        guard let rendered = cmark_render_html(document, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)) else {
            throw JoplinImportError.invalid("Markdown could not be rendered.")
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private static let registryLock = NSLock()

    public static func html(source: String, format: NoteFormat, resources: ImportedResources?,
                            options: PreviewOptions = PreviewOptions(), noteLinks: [String: UUID] = [:]) throws -> String {
        let input = format.usesHTML ? source : try markdownHTML(source)
        let safe = try NoteLinks.linkedBody(sanitizedBody(input, resources: resources), targets: noteLinks)
        let thumbnail = min(max(options.thumbnailSize, 64), 400)
        let imageSizing = options.thumbnailSize == 0
            ? "max-width: 100%; max-height: none;"
            : "max-width: min(100%, \(thumbnail)px); max-height: \(thumbnail)px;"
        let fontSize = min(max(options.fontSize, 11), 32)
        let dracula = options.theme == .dracula
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src folio-resource:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: \(dracula ? "dark" : "light dark");
          --bg: \(dracula ? "#282a36" : "Canvas"); --fg: \(dracula ? "#f8f8f2" : "CanvasText");
          --muted: \(dracula ? "#a5a9c5" : "GrayText"); --accent: \(dracula ? "#bd93f9" : "#5c51cc");
          --line: \(dracula ? "#44475a" : "color-mix(in srgb, CanvasText 18%, Canvas)");
          --code: \(dracula ? "#21222c" : "color-mix(in srgb, CanvasText 5%, Canvas)");
          --green: \(dracula ? "#50fa7b" : "#168143"); --pink: \(dracula ? "#ff79c6" : "#ae287b"); }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 28px 32px 64px; background: var(--bg); color: var(--fg);
          font: \(fontSize)px/1.7 \(options.font.css); overflow-wrap: anywhere; }
        main { max-width: \(options.fullWidth ? "none" : "860px"); margin: 0 auto; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.3; margin: 1.4em 0 .6em; color: var(--accent); }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; border-bottom: 1px solid var(--line); padding-bottom: .3em; }
        h3 { font-size: 1.2em; } p { margin: .8em 0; } a { color: var(--accent); }
        strong { color: var(--pink); } em { color: var(--green); }
        pre { background: var(--code); padding: 18px; border: 1px solid var(--line); border-radius: 8px; overflow-x: auto; }
        code { font-family: 'SF Mono', Menlo, monospace; background: var(--code); border-radius: 4px; padding: .12em .3em; }
        pre code { padding: 0; } blockquote { margin: 1em 0; border-left: 3px solid var(--accent);
          padding: .2em 1em; background: var(--code); border-radius: 0 6px 6px 0; color: var(--muted); }
        ul,ol { padding-left: 1.8em; } li { margin: .3em 0; } li > p { margin: .35em 0; }
        table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 1em 0; }
        td,th { border: 1px solid var(--line); padding: 8px 12px; min-width: 60px; }
        th { background: var(--code); color: var(--accent); } hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }
        img.folio-thumbnail { display: inline-block; \(imageSizing)
          width: auto !important; height: auto !important; object-fit: contain;
          border: 1px solid var(--line); border-radius: 6px; cursor: zoom-in; vertical-align: middle; margin: 6px 0; }
        img.folio-thumbnail:hover, img.folio-thumbnail:focus { outline: 2px solid var(--accent); }
        .folio-image-placeholder { display: inline-block; padding: 8px; color: var(--muted);
          border: 1px dashed var(--line); border-radius: 6px; font-size: .85em; }
        details { padding: 10px 14px; background: var(--code); border-radius: 6px; margin: 1em 0; }
        summary { cursor: pointer; color: var(--accent); } input[type=checkbox] { accent-color: var(--accent); }
        </style></head><body><main>\(safe)</main></body></html>
        """
    }

    public static func sanitizedBody(_ html: String, resources: ImportedResources?) throws -> String {
        let document = try SwiftSoup.parse(html)
        // Remove active content before cleaning, rather than retaining script text.
        try document.select("script,style,iframe,object,embed,form,base,link,meta,svg,math").remove()
        let whitelist = try Whitelist.relaxed()
            .addTags("input", "details", "summary", "figure", "figcaption", "del", "s", "kbd", "hr")
            .addAttributes("input", "type", "checked", "disabled")
            .addAttributes("a", "id", "name")
            .addAttributes("h1", "id").addAttributes("h2", "id").addAttributes("h3", "id")
            .addAttributes("td", "align").addAttributes("th", "align")
            .removeProtocols("a", "href", "ftp")
        // URLs are explicitly resolved and allowlisted below, including relative paths.
        try whitelist.removeProtocols("img", "src", "http", "https")
        try whitelist.removeProtocols("a", "href", "http", "https", "mailto")
        let cleaned = try SwiftSoup.clean(try document.body()?.html() ?? "", whitelist)
        let body = try SwiftSoup.parseBodyFragment(cleaned ?? "")
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
            if let local = resources?.previewURL(for: reference) {
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
