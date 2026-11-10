import NotesCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WebKit

typealias MobileState<Value> = SwiftUI.State<Value>

@main
struct FolioMobileApp: App {
    @StateObject private var store = NotesStore(readOnly: true)

    var body: some Scene {
        WindowGroup {
            MobileReaderView().environmentObject(store)
        }
    }
}

struct MobileReaderView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @MobileState private var connectingFolder = false
    @MobileState private var searchingAll = false
    @MobileState private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $store.scope) {
                Section("Library") {
                    Label("All Notes", systemImage: "tray.full").tag(NoteScope.all)
                    Label("Pinned", systemImage: "pin").tag(NoteScope.pinned)
                }
                Section("Notebooks") {
                    ForEach(NotebookBranch.build(store.library.notebooks)) { branch in
                        readerBranch(branch)
                    }
                }
                if !store.tags.isEmpty {
                    Section("Tags") {
                        ForEach(store.tags, id: \.self) { tag in
                            Label(tag, systemImage: "number").tag(NoteScope.tag(tag))
                        }
                    }
                }
                Section("Offline reader") {
                    Label("Read here. Write on your Mac.", systemImage: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Connect iCloud Drive Folder", systemImage: "icloud") { connectingFolder = true }
                        .disabled(!store.isLoaded || store.isSyncing)
                    if store.syncFolderName != nil {
                        Button(store.isSyncing ? "Refreshing..." : "Refresh from Mac",
                               systemImage: "arrow.triangle.2.circlepath", action: store.syncNow)
                            .disabled(store.isSyncing)
                        Button("Disconnect", action: store.disconnectSyncFolder).disabled(store.isSyncing)
                    }
                    Text(store.syncMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .navigationTitle("Folio")
        } content: {
            List(selection: $store.selectedNoteID) {
                ForEach(store.visibleNotes) { note in
                    NavigationLink(value: note.id) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(note.displayTitle).font(.headline).lineLimit(1)
                            Text(note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(note.updatedAt, style: .date)
                                Spacer()
                                if note.isPinned { Image(systemName: "pin.fill") }
                            }.font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 7)
                    }
                }
            }
            .navigationTitle(store.scopeTitle)
            .searchable(text: $store.query, prompt: "Search this notebook")
            .toolbar {
                Button("Search All Notes", systemImage: "magnifyingglass") { searchingAll = true }
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath", action: store.syncNow)
                    .disabled(store.syncFolderName == nil || store.isSyncing)
            }
        } detail: {
            if let note = store.selectedNote {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(note.displayTitle).font(.largeTitle.weight(.bold)).textSelection(.enabled)
                        HStack {
                            Text(note.updatedAt, style: .date)
                            if !note.tags.isEmpty { Text(note.tags.map { "#\($0)" }.joined(separator: "  ")).lineLimit(1) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(24)
                    MobilePreview(note: note).id(note.id)
                    HStack {
                        Label("Available offline", systemImage: "internaldrive")
                        Spacer()
                        Text("\(note.wordCount) words")
                    }.font(.caption).foregroundStyle(.secondary).padding(14)
                }
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView {
                    Label("Your library. Wherever you are.", systemImage: "books.vertical")
                } description: {
                    Text("Connect the same iCloud Drive folder you chose on your Mac. Refresh once to keep a local copy for offline reading.")
                } actions: {
                    Button("Connect iCloud Drive Folder") { connectingFolder = true }
                }
            }
        }
        .preferredColorScheme(theme == FolioTheme.dracula.rawValue ? .dark : nil)
        .tint(theme == FolioTheme.dracula.rawValue ? .purple : .accentColor)
        .onChange(of: store.scope) { _, _ in store.reconcileSelection() }
        .onChange(of: store.query) { _, _ in store.reconcileSelection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && store.syncFolderName != nil { store.syncNow() }
        }
        .fileImporter(isPresented: $connectingFolder, allowedContentTypes: [.folder]) { result in
            do {
                try store.connectSyncFolder(result.get())
                store.syncNow()
            } catch { store.errorMessage = "Could not connect folder: \(error.localizedDescription)" }
        }
        .alert("Folio needs your attention", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "") }
        .sheet(isPresented: $searchingAll) {
            NavigationStack {
                List(NoteSearch.find(search, in: store.library)) { result in
                    Button {
                        store.openNote(result.id)
                        searchingAll = false
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.note.displayTitle).font(.headline)
                            Text(result.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            Text(result.notebook).font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 7)
                    }.buttonStyle(.plain)
                }
                .navigationTitle("Find a thought")
                .searchable(text: $search, prompt: "Titles, text, tags and notebooks")
                .toolbar { Button("Done") { searchingAll = false } }
            }
        }
    }

    private func readerBranch(_ branch: NotebookBranch) -> AnyView {
        AnyView(Group {
            if branch.children.isEmpty && branch.notebooks.count == 1, let notebook = branch.notebooks.first {
                Label(branch.name, systemImage: "book.closed").tag(NoteScope.notebook(notebook.id))
            } else {
                DisclosureGroup {
                    ForEach(branch.notebooks) { notebook in
                        Label("Notes in \(branch.name)", systemImage: "book.closed").tag(NoteScope.notebook(notebook.id))
                    }
                    ForEach(branch.children) { child in readerBranch(child) }
                } label: {
                    Label(branch.name, systemImage: "folder").tag(NoteScope.folder(branch.id, branch.descendants))
                }
            }
        })
    }
}

private struct MobileImage: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobilePreview: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @MobileState private var html = ""
    @MobileState private var error: String?
    @MobileState private var expanded: MobileImage?

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

    private var request: MobileRenderRequest {
        MobileRenderRequest(source: note.body, format: note.contentFormat, theme: theme,
                            resources: resources, links: NoteLinks.targets(in: store.library))
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                MobileWebView(html: html, resources: resources) {
                    expanded = MobileImage(url: $0)
                } onError: { error = $0 } onNote: { store.openNote($0) }
            }
        }
        .task(id: request) {
            do {
                var options = PreviewOptions()
                options.theme = FolioTheme(rawValue: theme) ?? .system
                options.font = .system
                options.fontSize = 17
                html = try PreviewDocument.html(source: note.body, format: note.contentFormat, resources: resources,
                                               options: options, noteLinks: request.links)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $expanded) { image in
            NavigationStack {
                ZoomImage(url: image.url).ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Original image").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { expanded = nil } }
            }
        }
    }
}

private struct MobileRenderRequest: Equatable {
    let source: String
    let format: NoteFormat
    let theme: String
    let resources: ImportedResources?
    let links: [String: UUID]
}

private struct ZoomImage: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.delegate = context.coordinator
        let image = UIImageView(image: UIImage(contentsOfFile: url.path))
        image.contentMode = .scaleAspectFit
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        image.frame = scroll.bounds
        scroll.addSubview(image)
        context.coordinator.image = image
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var image: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    }
}

private struct MobileWebView: UIViewRepresentable {
    let html: String
    let resources: ImportedResources?
    let onImage: (URL) -> Void
    let onError: (String) -> Void
    let onNote: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "folio-resource")
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "expand")
        config.userContentController.addUserScript(WKUserScript(source: """
        document.addEventListener('click', event => {
          const image = event.target.closest('img.folio-thumbnail');
          if (image) { event.preventDefault(); event.stopPropagation(); window.webkit.messageHandlers.expand.postMessage(image.src); }
        }, true);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != html || context.coordinator.loadedResources != resources {
            context.coordinator.loaded = html
            context.coordinator.loadedResources = resources
            view.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "expand", contentWorld: .defaultClient)
    }
    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MobileWebView
        var loaded = ""
        var loadedResources: ImportedResources?
        init(parent: MobileWebView) { self.parent = parent }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String,
                  let url = URL(string: text), let local = parent.resources?.fileURL(for: url) else { return }
            parent.onImage(local)
        }
        func webView(_ view: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, let local = parent.resources?.fileURL(for: url),
                  UTType(filenameExtension: local.pathExtension)?.conforms(to: .image) == true,
                  local.pathExtension.lowercased() != "svg" else {
                task.didFailWithError(URLError(.noPermissionsToReadFile)); return
            }
            do {
                let data = try Data(contentsOf: local)
                task.didReceive(URLResponse(url: url, mimeType: UTType(filenameExtension: local.pathExtension)?.preferredMIMEType,
                                            expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } catch { task.didFailWithError(error) }
        }
        func webView(_ view: WKWebView, stop task: any WKURLSchemeTask) {}
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError(error.localizedDescription) }
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError(error.localizedDescription) }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" || (url.scheme == "about" && url.fragment != nil) {
                decisionHandler(.allow); return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, url.scheme == "folio-note",
               let host = url.host, let id = UUID(uuidString: host) {
                parent.onNote(id)
                return
            }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
        }
    }
}
