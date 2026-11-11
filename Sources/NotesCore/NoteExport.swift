import Foundation
import SwiftSoup

public enum NoteExportFormat: String, CaseIterable, Sendable {
    case markdown = "Markdown (.md)"
    case html = "HTML (.html)"
    case plainText = "Plain Text (.txt)"

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .plainText: "txt"
        }
    }

    public func contents(of note: Note) throws -> String {
        switch self {
        case .markdown:
            guard note.contentFormat == .html else { return note.body }
            do {
                return try FormattedPage(html: note.body).markdown()
            } catch {
                throw JoplinImportError.invalid("This HTML note could not be converted to Markdown: \(error.localizedDescription) Choose HTML to retain its layout.")
            }
        case .html:
            let document = try SwiftSoup.parse(PrintDocument.html(note: note))
            if let source = note.importedSourceURL, let root = note.importedRootURL {
                let resources = ImportedResources(source: source, root: root)
                for element in try document.select("img[src],a[href]") {
                    let attribute = element.tagName() == "img" ? "src" : "href"
                    let reference = try element.attr(attribute)
                    if let url = URL(string: reference), url.scheme == "folio-resource" {
                        guard let local = resources.fileURL(for: url) else {
                            throw JoplinImportError.invalid("An attachment points outside this note's resource folder.")
                        }
                        try element.attr(attribute, local.absoluteString)
                    }
                }
            }
            try document.select("meta[http-equiv=Content-Security-Policy]").attr("content",
                "default-src 'none'; img-src file:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'")
            return try document.outerHtml()
        case .plainText:
            let html = note.contentFormat == .html ? note.body : try PreviewDocument.markdownHTML(note.body)
            let document = try SwiftSoup.parse(html)
            try document.select("script,style,iframe,object,embed,head").remove()
            for image in try document.select("img") {
                let alternative = try image.attr("alt")
                try image.tagName("span").text(alternative)
            }
            for checkbox in try document.select("input[type=checkbox]") {
                let marker = checkbox.hasAttr("checked") ? "[x]" : "[ ]"
                try checkbox.tagName("span").text(marker)
            }
            for block in try document.select("p,div,section,article,li,tr,h1,h2,h3,h4,h5,h6,blockquote,pre") {
                try block.appendText("\n")
            }
            return try document.body()?.text(trimAndNormaliseWhitespace: false)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}
