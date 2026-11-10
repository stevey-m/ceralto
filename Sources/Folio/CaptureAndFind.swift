import AppKit
import NotesCore
import SwiftUI

struct QuickCaptureView: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("captureDraftTitle") private var title = ""
    @AppStorage("captureDraftBody") private var bodyText = ""
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @ViewState private var failure: String?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Catch a thought").font(.title2.weight(.semibold))
                    Text("Straight to Inbox. Organise it later.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.plain).font(.title3.weight(.medium))
                .accessibilityLabel("Quick capture title")
            Divider()
            TextEditor(text: $bodyText)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .focused($writing)
                .accessibilityLabel("Quick capture text")
                .overlay(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text("An idea, a quote, something to remember...")
                            .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Divider()
            HStack {
                Label("Draft kept on this Mac", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save to Inbox", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.isLoaded || (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                                 bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 350)
        .background(theme == FolioTheme.dracula.rawValue ? FolioPalette.background : Color(nsColor: .windowBackgroundColor))
        .folioAppearance()
        .onAppear { writing = true }
        .background(CaptureWindowStyle())
    }

    private func save() {
        do {
            _ = try store.capture(title: title, body: bodyText)
            title = ""
            bodyText = ""
            failure = nil
            dismissWindow(id: "capture")
        } catch {
            failure = "Not saved. Your draft is still here. \(error.localizedDescription)"
        }
    }
}

private struct CaptureWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FloatingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = .floating
            window?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }
    }
}

struct NoteFinder: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selection: UUID?
    @ViewState private var showingSearchHelp = false
    @FocusState private var searching: Bool

    private var results: [NoteSearchResult] { NoteSearch.find(query, in: store.library) }
    private var selected: NoteSearchResult? { results.first { $0.id == selection } ?? results.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Find anything in your notes", text: $query)
                    .font(.title3).textFieldStyle(.plain).focused($searching)
                    .onSubmit(open)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            if let error = NoteQuery(query).errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(result.note.displayTitle).font(.headline).lineLimit(1)
                            Text(result.snippet.isEmpty ? "Empty note" : result.snippet)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            Label(result.notebook, systemImage: "book.closed")
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.openNote(result.id); dismiss() }
                    }
                }
                .listStyle(.inset)
                .frame(width: 310)
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                Divider()
                if let selected {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(selected.note.displayTitle)
                            .font(.title2.weight(.semibold)).padding(22)
                        MarkdownPreview(note: selected.note).id(selected.id)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Your memory, within reach", systemImage: "sparkle.magnifyingglass",
                                           description: Text("Search titles, text, tags and notebook names."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(query.isEmpty ? "Recently edited notes" : "\(results.count) results\(results.count == 80 ? " (first 80)" : "")")
                Button("Search Help") { showingSearchHelp.toggle() }
                    .popover(isPresented: $showingSearchHelp) { SearchSyntaxHelp().padding(20).frame(width: 440) }
                Spacer()
                Text("Arrow keys to choose").foregroundStyle(.tertiary)
                Button("Open Note", action: open).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(width: 840, height: 560)
        .folioAppearance()
        .onAppear { searching = true; selection = results.first?.id }
        .onChange(of: query) { _, _ in selection = results.first?.id }
    }

    private func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(0, current + offset), results.count - 1)].id
    }

    private func open() {
        guard let selected else { return }
        store.openNote(selected.id)
        dismiss()
    }
}
