import AppKit
import NotesCore
import SwiftUI
import SwiftSoup
import Testing
import WebKit
@testable import Folio

@Suite(.serialized)
@MainActor
struct ImportedNoteEditorTests {
    @Test(arguments: [NoteFormat.html, .markdown])
    func importedTextEditsAndSelectedSizesPersistWithoutConvertingLayoutAndSupportUndo(format: NoteFormat) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CeraltoImportedEditor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Imported")
        let original = """
        <table role='none' width='100%'><tr><td class='email'>
        <p>Editable words</p><p><img src='../_resources/original.png'></p>
        <p><span style='font-size:12px'>Before </span><b style='font-size:21px'>bold words</b><span style='font-size:34px'> after</span></p>
        </td></tr></table><h3>Keep heading</h3>
        """
        let note = Note(notebookID: notebook.id, title: "Synthetic imported note",
                        body: original, format: format)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        let actions = ImportedTextActions()
        var error: String?
        let view = PreservedDocumentView(source: original, format: format, resources: nil, options: PreviewOptions(),
            actions: actions, currentSource: { store.library.notes.first?.body },
            onChange: { body in store.update(note.id) { $0.body = body } },
            onError: { error = $0 }, onImage: { _ in })
        let host = NSHostingView(rootView: view.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<120 where !actions.ready { try await Task.sleep(for: .milliseconds(25)) }
        #expect(actions.ready)
        let web = try #require(actions.webView)
        #expect(store.library.notes.first?.body == original)
        try await select("Editable words", in: web)
        _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, 'Revised words')")
        try await waitFor { store.library.notes.first?.body.contains("Revised words") == true }
        let edited = try #require(store.library.notes.first)
        #expect(edited.body == original.replacingOccurrences(of: "Editable words", with: "Revised words"))
        #expect(edited.contentFormat == format)
        #expect(try storage.load()?.notes.first?.body == edited.body)
        _ = try await web.evaluateJavaScript("document.execCommand('undo')")
        try await waitFor { store.library.notes.first?.body == original }
        #expect(store.library.notes.first?.body == original)
        _ = try await web.evaluateJavaScript("document.execCommand('redo')")
        try await waitFor { store.library.notes.first?.body == edited.body }
        try await select("Revised words", in: web)
        actions.perform("size", value: 24)
        try await waitFor { store.library.notes.first?.body.contains("font-size:24") == true }
        let sized = try #require(store.library.notes.first)
        #expect(sized.body.contains("<table role='none' width='100%'><tr><td class='email'>"))
        #expect(sized.body.contains("<img src='../_resources/original.png'>"))
        #expect(sized.body.contains("<h3>Keep heading</h3>"))
        #expect(!sized.body.contains("data-ceralto-edit"))
        #expect(try storage.load()?.notes.first?.body == sized.body)
        #expect(defaults.object(forKey: "editorFontSize") == nil)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('img').length") as? Int == 0)
        #expect(error == nil)
        #expect(window.makeFirstResponder(web))
        let larger = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: ">", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47))
        #expect(web.performKeyEquivalent(with: larger))
        try await waitFor { store.library.notes.first?.body.contains("font-size:25") == true }

        _ = try await web.evaluateJavaScript("""
        const spans = [...document.querySelectorAll('[data-ceralto-edit]')];
        const first = spans.find(item => item.textContent === 'Before ');
        const last = spans.find(item => item.textContent === ' after');
        first.focus();
        const range = document.createRange();
        range.setStart(first.firstChild, 0); range.setEnd(last.firstChild, last.textContent.length);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        """)
        try await Task.sleep(for: .milliseconds(30))
        actions.perform("adjustSize", value: 1)
        try await waitFor { store.library.notes.first?.body.contains("font-size:13") == true }
        #expect(try await web.evaluateJavaScript("""
        [...document.querySelectorAll('[data-ceralto-edit]')]
          .filter(node => ['Before', 'bold words', 'after'].includes(node.textContent.trim()))
          .map(node => getComputedStyle(document.createTreeWalker(node, NodeFilter.SHOW_TEXT).nextNode().parentElement).fontSize)
          .join(',')
        """) as? String == "13px,22px,35px")
        actions.perform("size", value: 28)
        try await waitFor { store.library.notes.first?.body.contains("font-size:28") == true }
        let multi = try SwiftSoup.parse(try #require(store.library.notes.first?.body))
        #expect(try multi.select("span[style*=28]").count == 3)
        #expect(try multi.select("b").text() == "bold words")
        actions.perform("adjustSize", value: 1)
        try await waitFor { store.library.notes.first?.body.contains("font-size:29") == true }
        let adjusted = try SwiftSoup.parse(try #require(store.library.notes.first?.body))
        #expect(try adjusted.select("span[style*=29]").count == 3)
        #expect(try await web.evaluateJavaScript("""
        [...document.querySelectorAll('[data-ceralto-edit]')]
          .filter(node => ['Before', 'bold words', 'after'].includes(node.textContent.trim()))
          .every(node => getComputedStyle(document.createTreeWalker(node, NodeFilter.SHOW_TEXT).nextNode().parentElement).fontSize === '29px')
        """) as? Bool == true)
        #expect(error == nil)

        try await select("bold words", in: web)
        actions.perform("bold")
        try await waitFor { store.library.notes.first?.body.contains("font-weight:normal") == true }
        #expect(error == nil)
        let beforeReplacement = store.library.notes.first?.body
        _ = try await web.evaluateJavaScript("""
        {
        const nodes = [...document.querySelectorAll('[data-ceralto-edit]')];
        const first = nodes.find(item => item.textContent.trim() === 'Before');
        const last = nodes.find(item => item.textContent.trim() === 'after');
        first.focus();
        const replacement = document.createRange();
        replacement.selectNodeContents(first); replacement.setEnd(last, last.childNodes.length);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(replacement);
        first.dispatchEvent(new InputEvent('beforeinput', {
          bubbles:true, cancelable:true, inputType:'insertText', data:'Replacement across styles'
        }));
        }
        """)
        try await waitFor { store.library.notes.first?.body.contains("Replacement across styles") == true }
        #expect(error == nil)
        #expect(store.library.notes.first?.body.contains("<img src='../_resources/original.png'>") == true)
        for _ in 0..<3 where store.library.notes.first?.body != beforeReplacement {
            let previous = store.library.notes.first?.body
            _ = try await web.evaluateJavaScript("document.execCommand('undo')")
            try await waitFor { store.library.notes.first?.body != previous }
        }
        #expect(store.library.notes.first?.body == beforeReplacement)
        let accepted = store.library.notes.first?.body
        _ = try await web.evaluateJavaScript("""
        const damaged = document.querySelector('[data-ceralto-edit]');
        damaged.innerHTML = '<img src="https://example.test/blocked">';
        damaged.dispatchEvent(new InputEvent('input', {bubbles:true}));
        """)
        try await waitFor { error != nil }
        #expect(store.library.notes.first?.body == accepted)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-ceralto-edit] img').length") as? Int == 0)
        #expect(try storage.load()?.notes.first?.body == accepted)
        error = nil
        let external = try #require(accepted) + "<p>Concurrent update</p>"
        store.update(note.id) { $0.body = external }
        try await select("Revised words", in: web)
        _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, 'Stale replacement')")
        try await waitFor { error != nil }
        #expect(store.library.notes.first?.body == external)
        #expect(try storage.load()?.notes.first?.body == external)
    }

    @Test func noteWindowOpensUnsupportedHtmlReadyForDirectEditingWithoutRewritingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CeraltoImportedWindow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notebook = Notebook(name: "Imported")
        let source = "<details open><summary>More</summary><p>Editable body</p></details><hr><h3>A heading</h3>"
        let note = Note(notebookID: notebook.id, title: "Synthetic imported fixture", body: source, format: .html)
        let storage = LibraryStorage(url: root.appendingPathComponent("library.json"))
        try storage.save(Library(notebooks: [notebook], notes: [note]))
        let store = NotesStore(storage: storage, preferences: defaults)
        store.openNote(note.id)
        let host = NSHostingView(rootView: ContentView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var web: WKWebView?
        for _ in 0..<120 {
            host.layoutSubtreeIfNeeded()
            web = descendants(host).compactMap { $0 as? NoteDocumentWebView }.first { $0.importedActions?.ready == true }
            if web != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let editor = try #require(web)
        #expect(store.selectedNote?.body == source)
        try await select("Editable body", in: editor)
        _ = try await editor.evaluateJavaScript("document.execCommand('insertText', false, 'Edited directly')")
        try await waitFor { store.selectedNote?.body.contains("Edited directly") == true }
        #expect(store.selectedNote?.body == source.replacingOccurrences(of: "Editable body", with: "Edited directly"))
        #expect(try storage.load()?.notes.first?.body == store.selectedNote?.body)
        #expect(store.errorMessage == nil)
    }

    private func select(_ text: String, in web: WKWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
        const node = [...document.querySelectorAll('[data-ceralto-edit]')].find(item => item.textContent === text);
        if (!node) throw new Error('Missing synthetic text');
        node.focus();
        const range = document.createRange(); range.selectNodeContents(node);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        """, arguments: ["text": text], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate(), "The imported editor must persist its text and formatting changes.", sourceLocation: sourceLocation)
    }
}
