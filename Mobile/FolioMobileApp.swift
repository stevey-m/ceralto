import NotesCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WebKit

typealias MobileState<Value> = SwiftUI.State<Value>

private extension FolioTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .dracula: .dark
        }
    }
}

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
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @MobileState private var connectingFolder = false
    @MobileState private var searchingAll = false
    @MobileState private var search = ""
    @MobileState private var collapsedTopics: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List(selection: $store.mainFolderScope) {
                Section("Library") {
                    Label("All Notes", systemImage: "tray.full").tag(NoteScope.all)
                    Label("Pinned", systemImage: "pin").tag(NoteScope.pinned)
                }
                Section("Main Folders") {
                    ForEach(NotebookBranch.build(store.library.notebooks)) { branch in
                        Label(branch.name, systemImage: "folder").lineLimit(1)
                            .tag(NoteScope.folder(branch.id, branch.descendants))
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
                Section {
                    Menu {
                        Picker("Appearance", selection: $theme) {
                            ForEach(FolioTheme.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        Picker("Accent colour", selection: $accent) {
                            ForEach(FolioAccent.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                }
            }
            .navigationTitle("Deltos")
        } content: {
            List(selection: $store.selectedNoteID) {
                if let folder = store.navigationFolder {
                    ForEach(store.outlineNotes.filter { note in folder.notebooks.contains { $0.id == note.notebookID } }) { note in
                        readerNote(note)
                    }
                    ForEach(folder.children) { branch in readerTopic(branch) }
                } else {
                    ForEach(store.visibleNotes) { note in readerNote(note) }
                }
            }
            .navigationTitle(store.navigationFolder?.name ?? store.scopeTitle)
            .searchable(text: $store.query, prompt: "Search this notebook")
            .safeAreaInset(edge: .bottom) {
                if let error = store.searchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding().background(.bar)
                }
            }
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
        .preferredColorScheme((FolioTheme(rawValue: theme) ?? .system).colorScheme)
        .tint(accentColor)
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
        .alert("Deltos needs your attention", isPresented: Binding(
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
                .safeAreaInset(edge: .bottom) {
                    if let error = NoteQuery(search).errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).padding().background(.bar)
                    } else {
                        Text(#"Try tag:work, notebook:"Work/Ideas", is:pinned or -"old phrase"."#)
                            .font(.caption).foregroundStyle(.secondary).padding().background(.bar)
                    }
                }
                .toolbar { Button("Done") { searchingAll = false } }
            }
        }
    }

    private var accentColor: Color {
        let selected = FolioAccent(rawValue: accent) ?? .gold
        let scheme = (FolioTheme(rawValue: theme) ?? .system).colorScheme ?? colorScheme
        let hex = scheme == .dark ? selected.darkHex : selected.lightHex
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    private func readerNote(_ note: Note) -> some View {
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

    private func readerTopic(_ branch: NotebookBranch) -> AnyView {
        AnyView(Group {
            if store.query.isEmpty || store.outlineNotes.contains(where: { branch.descendants.contains($0.notebookID) }) {
                DisclosureGroup(isExpanded: Binding(
                    get: { !store.query.isEmpty || !collapsedTopics.contains(branch.id) },
                    set: { if $0 { collapsedTopics.remove(branch.id) } else { collapsedTopics.insert(branch.id) } }
                )) {
                    ForEach(store.outlineNotes.filter { note in branch.notebooks.contains { $0.id == note.notebookID } }) { note in
                        readerNote(note)
                    }
                    ForEach(branch.children) { child in readerTopic(child) }
                } label: {
                    Label(branch.name, systemImage: "folder").lineLimit(1)
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
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @MobileState private var html = ""
    @MobileState private var error: String?
    @MobileState private var expanded: MobileImage?

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

    private var request: MobileRenderRequest {
        let selected = FolioTheme(rawValue: theme) ?? .system
        let resolved = selected == .system ? (colorScheme == .dark ? FolioTheme.dark : .light) : selected
        return MobileRenderRequest(source: note.body, format: note.contentFormat, theme: resolved.rawValue, accent: accent,
                            resources: resources, links: NoteLinks.targets(in: store.library))
    }

    var body: some View {
        ZStack {
            previewContent
                .opacity(expanded == nil ? 1 : 0)
                .allowsHitTesting(expanded == nil)
                .accessibilityHidden(expanded != nil)
            if let expanded {
                VStack(spacing: 0) {
                    HStack {
                        Button { self.expanded = nil } label: {
                            Label("Back to note", systemImage: "chevron.left")
                        }
                        Spacer()
                        Text(expanded.url.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .padding()
                    Divider()
                    if UIImage(contentsOfFile: expanded.url.path) != nil {
                        ZoomImage(url: expanded.url).id(expanded.url)
                    } else {
                        ContentUnavailableView("Cannot open image", systemImage: "photo.badge.exclamationmark",
                                               description: Text("The file is missing or is not a supported image."))
                    }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .onChange(of: note.id) { _, _ in expanded = nil }
    }

    private var previewContent: some View {
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
                options.theme = FolioTheme(rawValue: request.theme) ?? .system
                options.accent = FolioAccent(rawValue: request.accent) ?? .gold
                options.font = .system
                options.fontSize = 17
                html = try PreviewDocument.html(source: note.body, format: note.contentFormat, resources: resources,
                                               options: options, noteLinks: request.links)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MobileRenderRequest: Equatable {
    let source: String
    let format: NoteFormat
    let theme: String
    let accent: String
    let resources: ImportedResources?
    let links: [String: UUID]
}

private struct ZoomImage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> UIScrollView {
        MobileImageScrollView(image: UIImage(contentsOfFile: url.path))
    }
    func updateUIView(_ view: UIScrollView, context: Context) {}
}

private final class MobileImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture: UIImageView
    private var viewport = CGSize.zero

    init(image: UIImage?) {
        picture = UIImageView(image: image)
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFit
        let size = image?.size ?? CGSize(width: 1, height: 1)
        picture.frame = CGRect(origin: .zero, size: size)
        addSubview(picture)
        contentSize = size
        delegate = self
        contentInsetAdjustmentBehavior = .never
        picture.accessibilityLabel = "Original image. Pinch to zoom and drag to pan."
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if viewport != bounds.size, bounds.width > 0, bounds.height > 0 {
            let wasFitted = viewport == .zero || abs(zoomScale - minimumZoomScale) < 0.001
            viewport = bounds.size
            let size = picture.bounds.size
            let fit = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
            minimumZoomScale = fit
            maximumZoomScale = max(8, fit * 8)
            if wasFitted { setZoomScale(fit, animated: false) }
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - picture.frame.width) / 2)
        let vertical = max(0, (bounds.height - picture.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
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
