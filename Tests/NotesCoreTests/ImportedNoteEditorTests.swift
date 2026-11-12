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
        let beforeMixedSizeChange = store.library.notes.first?.body
        actions.perform("adjustSize", value: 1)
        try await waitFor { store.library.notes.first?.body.contains("font-size:13") == true }
        let afterMixedSizeChange = store.library.notes.first?.body
        #expect(try await web.evaluateJavaScript("""
        [...document.querySelectorAll('[data-ceralto-edit]')]
          .filter(node => ['Before', 'bold words', 'after'].includes(node.textContent.trim()))
          .map(node => getComputedStyle(document.createTreeWalker(node, NodeFilter.SHOW_TEXT).nextNode().parentElement).fontSize)
          .join(',')
        """) as? String == "13px,22px,35px")
        #expect(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == beforeMixedSizeChange }
        #expect(window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == afterMixedSizeChange }
        let selectionAfterRedo = try await web.evaluateJavaScript("window.getSelection().getRangeAt(0).toString().replaceAll(String.fromCharCode(160), ' ')") as? String
        #expect(selectionAfterRedo == "Before bold words after")
        let copied = try await web.evaluateJavaScript("""
        (() => {
          const data = new DataTransfer();
          document.activeElement.dispatchEvent(new ClipboardEvent('copy', {bubbles:true, cancelable:true, clipboardData:data}));
          if (data.getData('text/html').includes('data-ceralto-edit')) throw new Error('Internal edit markers leaked into the clipboard');
          return data.getData('text/plain').replaceAll(String.fromCharCode(160), ' ');
        })()
        """) as? String
        #expect(copied == "Before bold words after")
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
        let replacedBody = store.library.notes.first?.body
        let undoKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        #expect(web.performKeyEquivalent(with: undoKey))
        try await waitFor { store.library.notes.first?.body == beforeReplacement }
        #expect(store.library.notes.first?.body == beforeReplacement)
        #expect(window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == replacedBody }
        #expect(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == beforeReplacement }
        try await select("Revised words", in: web)
        let beforePaste = store.library.notes.first?.body
        _ = try await web.evaluateJavaScript("""
        (() => {
          const data = new DataTransfer();
          data.setData('text/plain', 'One <literal>\\nTwo & caf\\u00e9\\n');
          data.setData('text/html', '<b>Unwanted rich content</b>');
          document.activeElement.dispatchEvent(new ClipboardEvent('paste', {bubbles:true, cancelable:true, clipboardData:data}));
        })()
        """)
        try await waitFor { store.library.notes.first?.body.contains("One &lt;literal&gt;<br>Two &amp; caf") == true }
        let pasted = store.library.notes.first?.body
        let pastedSource = try #require(pasted)
        let pastedParagraph = try #require(SwiftSoup.parse(pastedSource).select("p").first {
            try $0.text().contains("One <literal>")
        })
        func inlineText(_ node: Node) -> String {
            if let text = node as? TextNode { return text.getWholeText() }
            if (node as? Element)?.tagName() == "br" { return "\n" }
            return node.getChildNodes().map(inlineText).joined()
        }
        let pastedText = inlineText(pastedParagraph)
        #expect(pastedText == "One <literal>\nTwo & caf\u{e9}\n")
        #expect(!((pasted ?? "").contains("Unwanted rich content")))
        #expect(try storage.load()?.notes.first?.body == pasted)
        #expect(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == beforePaste }
        #expect(actions.canRedo)
        _ = try await web.evaluateJavaScript("document.execCommand('insertText', false, 'A new branch')")
        try await waitFor { store.library.notes.first?.body.contains("A new branch") == true }
        #expect(!actions.canRedo)
        let branched = store.library.notes.first?.body
        actions.perform("redo")
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.library.notes.first?.body == branched)
        #expect(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) == true)
        try await waitFor { store.library.notes.first?.body == beforePaste }
        try await select("Revised words", in: web)
        _ = try await web.evaluateJavaScript("""
        (() => {
          for (const text of ['a', 'b']) {
            const node = document.activeElement;
            if (node.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, cancelable:true, inputType:'insertText', data:text}))) {
              document.execCommand('insertText', false, text);
            }
          }
        })()
        """)
        try await waitFor { store.library.notes.first?.body.contains(">ab") == true }
        actions.perform("undo")
        try await waitFor { store.library.notes.first?.body == beforePaste }
        try await select("Revised words", in: web)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const node = document.activeElement;
          node.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true}));
          for (const text of ['n', 'ni', String.fromCharCode(0x4f60)]) {
            node.textContent = text;
            node.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertCompositionText', data:text, isComposing:true}));
          }
          node.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true}));
        })()
        """)
        try await waitFor { store.library.notes.first?.body.contains("\u{4f60}") == true }
        actions.perform("undo")
        try await waitFor { store.library.notes.first?.body == beforePaste }
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

    @Test(arguments: [false, true])
    func dismantlingDefersPublishedUpdatesAndDoesNotDisableAReplacementEditor(replaced: Bool) async throws {
        let actions = ImportedTextActions()
        let web = NoteDocumentWebView()
        let replacement = NoteDocumentWebView()
        actions.webView = web
        actions.ready = true
        let view = PreservedDocumentView(source: "<p>Body</p>", format: .html, resources: nil,
            options: PreviewOptions(), actions: actions, currentSource: { "<p>Body</p>" },
            onChange: { _ in }, onError: { Issue.record("\($0)") }, onImage: { _ in })
        let coordinator = view.makeCoordinator()
        PreservedDocumentView.dismantleNSView(web, coordinator: coordinator)
        #expect(!coordinator.active)
        #expect(actions.webView == nil)
        #expect(actions.ready)
        if replaced { actions.webView = replacement }
        try await Task.sleep(for: .milliseconds(20))
        #expect(actions.ready == replaced)
        #expect(actions.webView === (replaced ? replacement : nil))
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
        let selected = try await web.evaluateJavaScript("window.getSelection().toString()") as? String
        #expect(selected?.trimmingCharacters(in: .newlines) == text)
    }

    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate(), "The imported editor must persist its text and formatting changes.", sourceLocation: sourceLocation)
    }
}
