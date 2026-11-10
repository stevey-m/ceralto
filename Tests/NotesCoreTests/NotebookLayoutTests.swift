import AppKit
import NotesCore
import SwiftUI
import Testing
@testable import Folio

@MainActor
struct NotebookLayoutTests {
    @Test func selectingLongNotebookDoesNotExpandNavigationOrShrinkDocument() async throws {
        let suiteName = "FolioLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStore(storage: LibraryStorage(url: directory.appendingPathComponent("library.json")))
        let measurements = Measurements()
        let content = LayoutFixture(store: store, measurements: measurements).defaultAppStorage(defaults)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.frame = NSRect(x: 0, y: 0, width: 1240, height: 800)
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let before = measurements.widths
        #expect(before["notebooks"] == 220)
        #expect(before["notes"] == 250)
        #expect(before["document"] == 754)

        store.addNotebook(name: String(repeating: "A very long nested notebook name/", count: 8))
        store.createNote()
        if let id = store.selectedNoteID {
            store.update(id) { $0.title = String(repeating: "Long note title ", count: 30) }
        }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        #expect(measurements.widths == before)

        window.setContentSize(NSSize(width: 960, height: 800))
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        #expect((measurements.widths["document"] ?? 0) >= 520)
    }

    private final class Measurements {
        var widths: [String: Double] = [:]
    }

    private struct LayoutFixture: View {
        @ObservedObject var store: NotesStore
        let measurements: Measurements

        var body: some View {
            NotebookLayout(showNotebooks: true, showNotes: true) {
                List(store.library.notebooks) { Text($0.name) }
                    .background(WidthProbe(name: "notebooks", measurements: measurements))
            } notes: {
                List(store.visibleNotes) { Text($0.title) }
                    .background(WidthProbe(name: "notes", measurements: measurements))
            } document: {
                Text(store.selectedNote?.body ?? "No note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WidthProbe(name: "document", measurements: measurements))
            }
        }
    }

    private struct WidthProbe: NSViewRepresentable {
        let name: String
        let measurements: Measurements

        func makeNSView(context: Context) -> ProbeView {
            ProbeView { measurements.widths[name] = $0 }
        }
        func updateNSView(_ view: ProbeView, context: Context) {}
    }

    private final class ProbeView: NSView {
        let measure: (Double) -> Void
        init(measure: @escaping (Double) -> Void) {
            self.measure = measure
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            measure(bounds.width)
        }
    }
}
