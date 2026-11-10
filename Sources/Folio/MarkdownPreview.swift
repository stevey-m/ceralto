import AppKit
import NotesCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MarkdownPreview: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    var onImage: ((URL) -> Void)?
    @AppStorage("folioTheme") private var theme = FolioTheme.dracula.rawValue
    @AppStorage("readingFont") private var font = ReadingFont.monospace.rawValue
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("imageDisplayWidth") private var thumbnailSize = 0
    @AppStorage("fullWidthNotes") private var fullWidth = false
    @ViewState private var document = ""
    @ViewState private var renderError: String?
    @ViewState private var expandedImage: ImageSelection?

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

    private var options: PreviewOptions {
        var options = PreviewOptions()
        options.theme = FolioTheme(rawValue: theme) ?? .dracula
        options.font = ReadingFont(rawValue: font) ?? .monospace
        options.fontSize = fontSize
        options.thumbnailSize = thumbnailSize
        options.fullWidth = fullWidth
        return options
    }

    private var links: [String: UUID] { NoteLinks.targets(in: store.library) }

    var body: some View {
        ZStack {
            previewContent
                .opacity(expandedImage == nil ? 1 : 0)
                .allowsHitTesting(expandedImage == nil)
                .accessibilityHidden(expandedImage != nil)
            if let expandedImage {
                ImageDocumentView(url: expandedImage.url) { self.expandedImage = nil }
            }
        }
        .onChange(of: note.id) { _, _ in expandedImage = nil }
        .accessibilityLabel("Note preview")
    }

    private var previewContent: some View {
        Group {
            if let renderError {
                ContentUnavailableView("Could not display this note", systemImage: "exclamationmark.triangle",
                                       description: Text(renderError))
            } else {
                DocumentWebView(html: document, resources: resources) { url in
                    if let onImage { onImage(url) }
                    else { expandedImage = ImageSelection(url: url) }
                } onError: { renderError = $0 } onNote: { store.openNote($0) }
            }
        }
        .task(id: RenderRequest(source: note.body, format: note.contentFormat, resources: resources, options: options, links: links)) {
            let request = RenderRequest(source: note.body, format: note.contentFormat, resources: resources, options: options, links: links)
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await Task.detached(priority: .userInitiated) {
                    try PreviewDocument.html(source: request.source, format: request.format,
                                             resources: request.resources, options: request.options, noteLinks: request.links)
                }.value
                try Task.checkCancellation()
                renderError = nil
                document = result
            } catch is CancellationError {
                // A more recent edit has replaced this render request.
            } catch {
                renderError = error.localizedDescription
            }
        }
    }
}

private struct RenderRequest: Equatable {
    let source: String
    let format: NoteFormat
    let resources: ImportedResources?
    let options: PreviewOptions
    let links: [String: UUID]
}

private struct ImageSelection: Identifiable {
    let id = UUID()
    let url: URL
}

struct DocumentWebView: NSViewRepresentable {
    let html: String
    let resources: ImportedResources?
    var onImage: (URL) -> Void
    var onError: (String) -> Void
    var onNote: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "folio-resource")
        let controller = configuration.userContentController
        controller.add(coordinator, contentWorld: .defaultClient, name: "folioImage")
        controller.addUserScript(WKUserScript(
            source: Self.imageInteractionScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient
        ))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedHTML != html || context.coordinator.loadedResources != resources {
            context.coordinator.loadedHTML = html
            context.coordinator.loadedResources = resources
            view.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "folioImage", contentWorld: .defaultClient)
    }

    static let imageInteractionScript = """
    function expandImage(event) {
      const image = event.target.closest('img.folio-thumbnail');
      if (!image) return;
      if (event.type === 'keydown' && !['Enter', ' '].includes(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      window.webkit.messageHandlers.folioImage.postMessage(image.src);
    }
    document.addEventListener('click', expandImage, true);
    document.addEventListener('keydown', expandImage, true);
    document.querySelectorAll('img.folio-thumbnail').forEach(image => {
      image.addEventListener('error', () => {
        const missing = document.createElement('span');
        missing.className = 'folio-image-placeholder';
        missing.textContent = 'Image unavailable: ' + (image.alt || 'missing attachment');
        image.replaceWith(missing);
      });
    });
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var parent: DocumentWebView
        var loadedHTML: String?
        var loadedResources: ImportedResources?

        init(parent: DocumentWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let reference = message.body as? String,
                  let url = URL(string: reference), let local = parent.resources?.fileURL(for: url),
                  Self.isRasterImage(local) else { return }
            parent.onImage(local)
        }

        static func isRasterImage(_ url: URL) -> Bool {
            ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "tif", "bmp", "avif"].contains(url.pathExtension.lowercased())
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let local = parent.resources?.fileURL(for: url),
                  Self.isRasterImage(local) else {
                urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            do {
                let data = try Data(contentsOf: local)
                let mime = UTType(filenameExtension: local.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                                    textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                urlSchemeTask.didFailWithError(error)
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .other && url.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else if url.scheme == "about", url.fragment != nil {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                guard navigationAction.navigationType == .linkActivated else { return }
                if url.scheme == "folio-note", let host = url.host, let id = UUID(uuidString: host) {
                    parent.onNote(id)
                } else if let local = parent.resources?.fileURL(for: url) {
                    if Self.isRasterImage(local) { parent.onImage(local) }
                    else if !NSWorkspace.shared.open(local) {
                        parent.onError("This attachment could not be opened: \(local.lastPathComponent)")
                    }
                } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    if !NSWorkspace.shared.open(url) { parent.onError("This link could not be opened.") }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError(error.localizedDescription) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onError("The preview process stopped. Switch notes or change the note to reload it.")
        }
    }
}
