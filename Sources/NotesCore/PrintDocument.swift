import Foundation
import SwiftSoup

public enum PrintDocument {
    public static func html(note: Note) throws -> String {
        let resources: ImportedResources?
        if let source = note.importedSourceURL, let root = note.importedRootURL {
            resources = ImportedResources(source: source, root: root)
        } else {
            resources = nil
        }
        var options = PreviewOptions()
        options.theme = .light
        options.fullWidth = true
        options.fontSize = 14
        let document = try SwiftSoup.parse(PreviewDocument.html(source: note.body, format: note.contentFormat,
                                                               resources: resources, options: options))
        try document.head()?.appendElement("title").text(note.displayTitle)
        try document.select("main").first()?.prependElement("h1").attr("class", "folio-print-title").text(note.displayTitle)
        try document.head()?.appendElement("style").text("""
        :root { color-scheme: light; --bg: white; --fg: black; --muted: #444;
          --accent: #222; --line: #bbb; --code: #f4f4f4; }
        body { padding: 0; background: white; color: black; }
        .folio-print-title { margin-top: 0; }
        details > * { display: block; }
        @media print {
          main, main > * { max-width: none; }
          h1,h2,h3,h4,h5,h6 { break-after: avoid; }
          img.folio-thumbnail { max-width: 100%; max-height: 9in; width: auto !important;
            break-inside: avoid; border: 0; }
          pre { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; }
          .folio-table-scroll { overflow: visible; }
          table { width: 100%; table-layout: fixed; }
          td,th { overflow-wrap: anywhere; }
          thead { display: table-header-group; }
          tr { break-inside: avoid; }
        }
        """)
        for detail in try document.select("details") { try detail.attr("open", "") }
        return try document.outerHtml()
    }
}
