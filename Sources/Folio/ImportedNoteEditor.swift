import AppKit
import NotesCore
import SwiftUI
import SwiftSoup
import WebKit

@MainActor
final class ImportedTextActions: ObservableObject {
    weak var webView: WKWebView?
    @Published var ready = false
    @Published var selectedSize = ""
    @Published var canUndo = false
    @Published var canRedo = false
    var onError: (String) -> Void = { _ in }

    func perform(_ command: String, value: Double? = nil) {
        guard let webView, ready else { return }
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "return window.ceraltoEditor.command(command, value);",
                    arguments: ["command": command, "value": value.map { $0 as Any } ?? NSNull()],
                    in: nil, contentWorld: .defaultClient)
            } catch { onError("Could not format the imported text: \(error.localizedDescription)") }
        }
    }

    func applySize(_ text: String) {
        guard let size = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              size.isFinite, (1...512).contains(size) else {
            onError("Enter a numeric text size from 1 to 512 points.")
            return
        }
        perform("size", value: size)
    }
}

struct ImportedTextFormattingControls: View {
    @ObservedObject var actions: ImportedTextActions
    @ViewState private var showing = false
    @ViewState private var size = ""

    var body: some View {
        NoteToolbarButton(title: "Aa") {
            size = actions.selectedSize
            showing.toggle()
        }
        .help("Format selected imported text")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([("Bold", "bold"), ("Italic", "italic"), ("Underline", "underline"),
                             ("Strikethrough", "strikeThrough")], id: \.0) { title, command in
                        NoteToolbarButton(title: title, symbol: command == "strikeThrough" ? "strikethrough" : command) {
                            actions.perform(command)
                        }
                    }
                }
                Divider()
                HStack {
                    NoteToolbarButton(title: "Smaller Text", symbol: "textformat.size.smaller") {
                        actions.perform("adjustSize", value: -1)
                    }
                    TextField("Size", text: $size).textFieldStyle(.roundedBorder)
                        .frame(width: 60).accessibilityLabel("Selected imported text size in points")
                        .onSubmit { actions.applySize(size) }
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    NoteToolbarButton(title: "Larger Text", symbol: "textformat.size.larger") {
                        actions.perform("adjustSize", value: 1)
                    }
                }
                Menu("Selected Text Size") {
                    ForEach(FormattingActions.fontSizes, id: \.self) { value in
                        Button("\(value) pt") { actions.perform("size", value: Double(value)) }
                    }
                }
                Text("Edit text directly. Original tables, images and layout stay protected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(width: 230).folioAppearance()
            .onChange(of: actions.selectedSize) { _, value in size = value }
        }
        .disabled(!actions.ready)
    }
}

struct ImportedNoteEditor: View {
    @ThemeColors private var palette
    @EnvironmentObject private var store: NotesStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled
    @AppStorage("folioTheme") private var theme = FolioTheme.system.rawValue
    @AppStorage("folioAccent") private var accent = FolioAccent.gold.rawValue
    @AppStorage("folioDraculaAccent") private var draculaAccent = "Theme default"
    @AppStorage("readingFont") private var font = ReadingFont.system.rawValue
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("imageDisplayWidth") private var imageWidth = 0
    @AppStorage("fullWidthNotes") private var fullWidth = false
    let note: Note
    let actions: ImportedTextActions
    let onImage: (URL) -> Void

    var body: some View {
        PreservedDocumentView(source: note.body, format: note.contentFormat, resources: resources,
                              options: options, actions: actions, enabled: enabled,
                              currentSource: { store.library.notes.first { $0.id == note.id }?.body },
                              onChange: { body in store.update(note.id) { $0.body = body } },
                              onError: { store.errorMessage = $0 }, onImage: onImage,
                              onNote: { store.openNote($0) })
    }

    private var resources: ImportedResources? {
        guard let source = note.importedSourceURL, let root = note.importedRootURL else { return nil }
        return ImportedResources(source: source, root: root)
    }

    private var options: PreviewOptions {
        var value = PreviewOptions()
        let selected = FolioTheme(rawValue: theme) ?? .system
        value.theme = selected == .system ? (colorScheme == .dark ? .dark : .light) : selected
        value.accent = FolioAccent(rawValue: accent) ?? .gold
        value.draculaAccent = FolioAccent(rawValue: draculaAccent)
        value.palette = selected == .custom ? palette : nil
        value.font = ReadingFont(rawValue: font) ?? .system
        value.fontSize = fontSize
        value.thumbnailSize = imageWidth
        value.fullWidth = fullWidth
        return value
    }
}

struct PreservedDocumentView: NSViewRepresentable {
    let source: String
    let format: NoteFormat
    let resources: ImportedResources?
    let options: PreviewOptions
    let actions: ImportedTextActions
    var enabled = true
    let currentSource: () -> String?
    let onChange: (String) -> Void
    let onError: (String) -> Void
    let onImage: (URL) -> Void
    var onNote: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let web = DocumentWebView.makeWebView(coordinator: coordinator.resourceCoordinator)
        web.configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "ceraltoEdit")
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.editingScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        (web as? NoteDocumentWebView)?.importedActions = actions
        web.setAccessibilityLabel("Editable imported note")
        actions.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.resourceCoordinator.parent = coordinator.documentParent
        actions.onError = onError
        let liveSource = currentSource() ?? source
        do {
            if coordinator.lastWritten != liveSource || coordinator.model == nil ||
                coordinator.format != format || coordinator.resources != resources {
                let model = try PreservedNoteDocument(source: liveSource, format: format)
                let html = try PreviewDocument.html(source: model.renderedHTML, format: .html,
                    resources: resources, options: options, editableIDs: model.editableIDs)
                coordinator.model = model
                coordinator.lastWritten = liveSource
                coordinator.format = format
                coordinator.resources = resources
                coordinator.options = options
                web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
                Task { @MainActor [weak web, weak coordinator] in
                    guard let web, coordinator?.active == true, actions.webView === web, web.isLoading else { return }
                    actions.ready = false
                }
            } else if coordinator.options != options {
                coordinator.options = options
                if let model = coordinator.model {
                    let html = try PreviewDocument.html(source: model.renderedHTML, format: .html,
                        resources: resources, options: options, editableIDs: model.editableIDs)
                    let css = try SwiftSoup.parse(html).select("style").html()
                    coordinator.run(web, script: "document.head.querySelector('style').textContent = css;",
                                    arguments: ["css": css])
                }
            }
            if coordinator.enabled != enabled {
                coordinator.enabled = enabled
                coordinator.run(web, script: "window.ceraltoEditor?.setEnabled(enabled);", arguments: ["enabled": enabled])
            }
        } catch {
            let message = "Could not open this imported note for editing: \(error.localizedDescription)"
            Task { @MainActor [weak coordinator] in
                guard coordinator?.active == true else { return }
                coordinator?.parent.onError(message)
            }
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        web.stopLoading()
        web.navigationDelegate = nil
        for name in ["folioImage", "ceraltoEdit"] {
            web.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .defaultClient)
        }
        let actions = coordinator.parent.actions
        if actions.webView === web {
            actions.webView = nil
            // Publishing during SwiftUI graph destruction can crash older macOS releases.
            Task { @MainActor [weak actions] in
                guard let actions, actions.webView == nil else { return }
                actions.ready = false
                actions.selectedSize = ""
                actions.canUndo = false
                actions.canRedo = false
            }
        }
        (web as? NoteDocumentWebView)?.importedActions = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: PreservedDocumentView
        var model: PreservedNoteDocument?
        var lastWritten: String?
        var format: NoteFormat?
        var resources: ImportedResources?
        var options: PreviewOptions?
        var enabled = true
        var active = true
        lazy var resourceCoordinator = DocumentWebView.Coordinator(parent: documentParent)

        var documentParent: DocumentWebView {
            DocumentWebView(html: "", resources: parent.resources, onImage: parent.onImage,
                onError: parent.onError, onNote: parent.onNote, onLoaded: { [weak self] web in
                    guard let self, self.active, self.parent.actions.webView === web else { return }
                    self.parent.actions.ready = true
                    self.run(web, script: "window.ceraltoEditor?.setEnabled(enabled);",
                             arguments: ["enabled": self.parent.enabled])
                })
        }

        init(parent: PreservedDocumentView) { self.parent = parent }

        func run(_ web: WKWebView, script: String, arguments: [String: Any] = [:]) {
            Task { @MainActor in
                guard active, parent.actions.webView === web else { return }
                do {
                    _ = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
                } catch { parent.onError("The imported editor could not update: \(error.localizedDescription)") }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame, let data = message.body as? [String: Any] else { return }
            if let error = data["error"] as? String { parent.onError(error); return }
            if let size = data["size"] as? String { parent.actions.selectedSize = size }
            if let value = data["canUndo"] as? Bool { parent.actions.canUndo = value }
            if let value = data["canRedo"] as? Bool { parent.actions.canRedo = value }
            guard let changes = data["changes"] as? [String: String], let sequence = data["sequence"] as? Int,
                  let model, parent.enabled else { return }
            do {
                guard parent.currentSource() == lastWritten else {
                    throw NoteWorkflowError("This note changed outside this editor. Reopen it before making further changes.")
                }
                let updated = try model.applying(changes)
                if updated != lastWritten {
                    lastWritten = updated
                    parent.onChange(updated)
                }
            } catch {
                parent.onError(error.localizedDescription)
                if let web = parent.actions.webView {
                    run(web, script: "window.ceraltoEditor.reject(sequence);", arguments: ["sequence": sequence])
                }
                return
            }
            if let web = parent.actions.webView {
                run(web, script: "window.ceraltoEditor.accept(sequence);", arguments: ["sequence": sequence])
            }
        }
    }

    static let editingScript = #"""
    (() => {
      const selector = 'span[data-ceralto-edit]';
      const markers = [...document.querySelectorAll(selector)];
      const originals = new Map(markers.map(node => [node.dataset.ceraltoEdit, node.innerHTML]));
      let accepted = new Map(originals), savedRange = null, suppress = false, enabled = true;
      let pending = new Map();
      let sequence = 0, acknowledged = 0;
      let observed = new Map(originals), undo = [], redo = [], beforeSelection = null, composing = false;
      const post = data => window.webkit.messageHandlers.ceraltoEdit.postMessage(data);
      const markerFor = node => (node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement)?.closest(selector);
      const selection = () => window.getSelection();
      const error = text => post({error: text});
      const snapshot = () => new Map(markers.map(node => [node.dataset.ceraltoEdit, node.innerHTML]));
      const inlineText = node => node.nodeType === Node.TEXT_NODE ? node.data :
        node.nodeName === 'BR' ? '\n' : [...node.childNodes].map(inlineText).join('');
      const length = node => (node.textContent || '').length +
        (node.querySelectorAll ? node.querySelectorAll('br').length : 0);
      function bookmark() {
        const current = selection();
        const point = (node, offset) => {
          const host = markerFor(node);
          if (!host) return null;
          const prefix = document.createRange(); prefix.selectNodeContents(host); prefix.setEnd(node, offset);
          return {id: host.dataset.ceraltoEdit, offset: length(prefix.cloneContents())};
        };
        if (!current.rangeCount) return null;
        const range = current.getRangeAt(0);
        const start = point(range.startContainer, range.startOffset), end = point(range.endContainer, range.endOffset);
        const backward = current.anchorNode === range.endContainer && current.anchorOffset === range.endOffset;
        return start && end ? {anchor: backward ? end : start, focus: backward ? start : end} : null;
      }
      function restoreBookmark(value) {
        if (!value) return;
        const point = target => {
          const host = markers.find(node => node.dataset.ceraltoEdit === target.id);
          if (!host) return null;
          const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
          let remaining = target.offset, node;
          while ((node = walker.nextNode())) {
            if (node.nodeType === Node.TEXT_NODE) {
              if (remaining <= node.length) return [node, remaining];
              remaining -= node.length;
            } else if (node.nodeName === 'BR') {
              if (remaining === 0) return [node.parentNode, [...node.parentNode.childNodes].indexOf(node)];
              remaining -= 1;
              if (remaining === 0) return [node.parentNode, [...node.parentNode.childNodes].indexOf(node) + 1];
            }
          }
          return [host, host.childNodes.length];
        };
        const anchor = point(value.anchor), focus = point(value.focus);
        if (!anchor || !focus) return;
        markerFor(anchor[0]).focus({preventScroll: true});
        const range = document.createRange();
        range.setStart(...anchor); range.setEnd(...focus);
        const backward = range.collapsed && JSON.stringify(value.anchor) !== JSON.stringify(value.focus);
        if (backward) { range.setStart(...focus); range.setEnd(...anchor); }
        selection().removeAllRanges(); selection().addRange(range);
        // WebKit clips setBaseAndExtent at editing-host boundaries.
        if (backward && value.anchor.id === value.focus.id) selection().setBaseAndExtent(...anchor, ...focus);
        savedRange = range.cloneRange();
      }
      let lastSelection = null;
      function remember(kind) {
        const current = snapshot(), patches = [];
        current.forEach((html, id) => {
          if (html !== observed.get(id)) patches.push({id, before: observed.get(id), after: html});
        });
        if (patches.length) {
          const after = bookmark(), before = beforeSelection || lastSelection;
          const previous = undo.at(-1), now = performance.now();
          const typing = ['insertText', 'deleteContentBackward', 'deleteContentForward'].includes(kind);
          const merged = typing && previous?.kind === kind && now - previous.time < 1000 &&
            JSON.stringify(previous.afterSelection) === JSON.stringify(before) &&
            previous.patches.length === 1 && patches.length === 1 && previous.patches[0].id === patches[0].id;
          if (merged) {
            previous.patches[0].after = patches[0].after;
            previous.afterSelection = after; previous.time = now;
          } else undo.push({patches, beforeSelection: before, afterSelection: after, kind, time: now});
          redo = [];
          let bytes = undo.reduce((total, entry) => total + entry.patches.reduce(
            (size, patch) => size + (patch.before.length + patch.after.length) * 2, 0), 0);
          while (undo.length > 1 && (undo.length > 100 || bytes > 16 * 1024 * 1024)) {
            bytes -= undo.shift().patches.reduce((size, patch) => size + (patch.before.length + patch.after.length) * 2, 0);
          }
        }
        observed = current; beforeSelection = null; lastSelection = bookmark();
      }
      function travel(backward) {
        if (!enabled) return false;
        const source = backward ? undo : redo, destination = backward ? redo : undo;
        const entry = source.pop();
        if (!entry) return false;
        if (undo.length) undo.at(-1).time = -Infinity;
        entry.time = -Infinity;
        suppress = true;
        try {
          entry.patches.forEach(patch => {
            markers.find(node => node.dataset.ceraltoEdit === patch.id).innerHTML = backward ? patch.before : patch.after;
          });
          restoreBookmark(backward ? entry.beforeSelection : entry.afterSelection);
          observed = snapshot(); lastSelection = bookmark(); beforeSelection = null;
          destination.push(entry);
        } finally { suppress = false; }
        notify('', false);
        return true;
      }
      const normalize = node => {
        const clone = node.cloneNode(true);
        clone.querySelectorAll('[class]').forEach(item => item.removeAttribute('class'));
        // WebKit ends an editing host with a caret placeholder, not a stored line break.
        if (clone.lastChild?.nodeName === 'BR') clone.lastChild.remove();
        return clone.innerHTML;
      };
      function notify(kind = 'edit', record = true) {
        if (suppress) return;
        if (record) remember(kind);
        const changes = {};
        markers.forEach(node => {
          if (node.innerHTML !== originals.get(node.dataset.ceraltoEdit)) {
            changes[node.dataset.ceraltoEdit] = normalize(node);
          }
        });
        sequence += 1;
        pending.set(sequence, new Map(markers.map(node => [node.dataset.ceraltoEdit, node.innerHTML])));
        post({changes, sequence, canUndo: undo.length > 0, canRedo: redo.length > 0});
      }
      function restoreRange() {
        if (!savedRange || !savedRange.commonAncestorContainer.isConnected) return false;
        selection().removeAllRanges(); selection().addRange(savedRange);
        return true;
      }
      function replaceSections(range, text) {
        beforeSelection = bookmark();
        const first = markerFor(range.startContainer), last = markerFor(range.endContainer);
        if (!first || !last) { error('Keep the selection inside editable text. Use Source to restructure the layout.'); return; }
        const parts = markers.filter(node => range.intersectsNode(node)).map(node => {
          const part = document.createRange(); part.selectNodeContents(node);
          if (node === first) part.setStart(range.startContainer, range.startOffset);
          if (node === last) part.setEnd(range.endContainer, range.endOffset);
          return part;
        });
        const prefix = document.createRange(); prefix.selectNodeContents(first);
        prefix.setEnd(parts[0].startContainer, parts[0].startOffset);
        const prefixContent = prefix.cloneContents();
        if (parts[0].startContainer === first && parts[0].startOffset === first.childNodes.length &&
            prefixContent.lastChild?.nodeName === 'BR') prefixContent.lastChild.remove();
        const suffix = document.createRange(); suffix.selectNodeContents(first);
        suffix.setStart(parts[0].endContainer, parts[0].endOffset);
        const suffixContent = suffix.cloneContents();
        if (suffixContent.lastChild?.nodeName === 'BR') suffixContent.lastChild.remove();
        const expectedText = inlineText(prefixContent) + text.replace(/\r\n?/g, '\n') + inlineText(suffixContent);
        const previous = new Map(markers.map(node => [node, node.innerHTML]));
        suppress = true;
        try {
          for (let index = parts.length - 1; index >= 0; index--) {
            selection().removeAllRanges(); selection().addRange(parts[index]);
            const inserted = index === 0 ? text : '';
            const html = inserted.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
              .replace(/\r\n?/g, '\n').replaceAll('\n', '<br>');
            if (!document.execCommand(inserted ? 'insertHTML' : 'delete', false, html)) {
              throw new Error('The selected text could not be replaced.');
            }
          }
          const breaks = expectedText.match(/\n+$/)?.[0].length || 0;
          if (breaks) {
            let current = inlineText(first).match(/\n+$/)?.[0].length || 0;
            while (current++ < breaks + 1) first.append(document.createElement('br'));
          }
          if (selection().rangeCount) savedRange = selection().getRangeAt(0).cloneRange();
        } catch (failure) {
          previous.forEach((html, node) => { node.innerHTML = html; });
          savedRange = null;
          error(failure.message);
        } finally { suppress = false; }
        notify('Replace Text');
      }
      document.addEventListener('selectionchange', () => {
        const current = selection();
        if (!current.rangeCount) return;
        const range = current.getRangeAt(0);
        if (!markerFor(range.startContainer) || !markerFor(range.endContainer)) return;
        savedRange = range.cloneRange();
        if (!suppress && !composing) lastSelection = bookmark();
        const sizes = new Set();
        markers.filter(node => range.intersectsNode(node)).forEach(node => {
          const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
          let text;
          while ((text = walker.nextNode())) {
            if (range.intersectsNode(text)) sizes.add(parseFloat(getComputedStyle(text.parentElement).fontSize));
          }
        });
        const size = sizes.size === 1 ? [...sizes][0] : NaN;
        post({size: Number.isFinite(size) ? String(Math.round(size * 100) / 100) : ''});
      });
      document.addEventListener('beforeinput', event => {
        if (!enabled) { event.preventDefault(); return; }
        if (suppress) return;
        if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
          event.preventDefault(); travel(event.inputType === 'historyUndo'); return;
        }
        if (!composing) beforeSelection = bookmark();
        const current = selection();
        if (!current.rangeCount) return;
        const range = current.getRangeAt(0);
        const first = markerFor(range.startContainer), last = markerFor(range.endContainer);
        if (first && last && first !== last && !event.isComposing &&
            (['insertText', 'insertReplacementText'].includes(event.inputType) && typeof event.data === 'string' ||
             ['deleteContentBackward', 'deleteContentForward', 'deleteByCut'].includes(event.inputType))) {
          event.preventDefault();
          replaceSections(range.cloneRange(), event.data || '');
          return;
        }
        if (!first || first !== last) {
          event.preventDefault();
          error('Edit within one text section to preserve this imported layout. Use Source to restructure it.');
          return;
        }
        if (event.inputType === 'insertParagraph') {
          event.preventDefault(); document.execCommand('insertLineBreak');
        }
      }, true);
      document.addEventListener('input', event => {
        if (suppress || composing) return;
        if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
          queueMicrotask(() => {
            observed.forEach((html, id) => { markers.find(node => node.dataset.ceraltoEdit === id).innerHTML = html; });
            travel(event.inputType === 'historyUndo');
          });
        } else notify(event.inputType || 'edit');
      });
      document.addEventListener('compositionstart', () => { beforeSelection = bookmark(); composing = true; });
      document.addEventListener('compositionend', () => {
        queueMicrotask(() => { composing = false; notify('Composition'); });
      });
      document.addEventListener('keydown', event => {
        if (enabled && event.metaKey && !event.altKey && !event.ctrlKey && event.key.toLowerCase() === 'z') {
          event.preventDefault(); travel(!event.shiftKey);
        }
      }, true);
      for (const type of ['copy', 'cut']) document.addEventListener(type, event => {
        const range = selection().rangeCount ? selection().getRangeAt(0) : null;
        if (!range || !markerFor(range.startContainer) || !markerFor(range.endContainer) ||
            markerFor(range.startContainer) === markerFor(range.endContainer)) return;
        event.preventDefault();
        const contents = document.createElement('div'); contents.append(range.cloneContents());
        contents.querySelectorAll(selector).forEach(node => node.replaceWith(...node.childNodes));
        event.clipboardData.setData('text/html', contents.innerHTML);
        contents.querySelectorAll('p,div,li,h1,h2,h3,h4,h5,h6,blockquote,tr,pre').forEach(node => node.append(document.createTextNode('\n')));
        const plain = inlineText(contents);
        event.clipboardData.setData('text/plain', ['P','DIV','LI','H1','H2','H3','H4','H5','H6','BLOCKQUOTE','TR','PRE'].includes(contents.lastChild?.nodeName) ?
          plain.replace(/\n$/, '') : plain);
        if (type === 'cut' && enabled) replaceSections(range.cloneRange(), '');
      }, true);
      document.addEventListener('paste', event => {
        if (!markerFor(event.target)) return;
        event.preventDefault();
        const data = event.clipboardData;
        if (data.files.length) { error('Use Add Attachments to insert files or images.'); return; }
        const range = selection().rangeCount ? selection().getRangeAt(0) : null;
        if (range && enabled && data.getData('text/plain')) replaceSections(range.cloneRange(), data.getData('text/plain'));
      }, true);
      document.addEventListener('drop', event => {
        event.preventDefault(); error('Use Add Attachments to insert files or images into imported notes.');
      }, true);
      const style = document.createElement('style');
      style.textContent = '[data-ceralto-edit][contenteditable=true]{outline:none;cursor:text} [data-ceralto-edit]:empty{display:inline-block;min-width:1ch;min-height:1em}';
      document.head.append(style);
      window.ceraltoEditor = {
        setEnabled(value) {
          enabled = value;
          markers.forEach(node => { node.contentEditable = String(value); node.spellcheck = true; });
        },
        accept(value) {
          if (value <= acknowledged || !pending.has(value)) return;
          acknowledged = value; accepted = pending.get(value);
          [...pending.keys()].forEach(key => { if (key <= value) pending.delete(key); });
        },
        reject(value) {
          suppress = true;
          markers.forEach(node => { node.innerHTML = accepted.get(node.dataset.ceraltoEdit); });
          [...pending.keys()].forEach(key => { if (key >= value) pending.delete(key); });
          savedRange = null;
          observed = snapshot(); undo = []; redo = []; beforeSelection = null; lastSelection = null;
          post({canUndo: false, canRedo: false});
          suppress = false;
        },
        command(command, value) {
          if (command === 'undo' || command === 'redo') return travel(command === 'undo');
          if (!enabled || !restoreRange()) { error('Select text in the note before formatting it.'); return false; }
          const range = selection().getRangeAt(0);
          const previousSelection = bookmark();
          beforeSelection = previousSelection;
          const sizing = command === 'size' || command === 'adjustSize';
          const applyTrait = !sizing && !document.queryCommandState(command);
          if (range.collapsed) {
            if (sizing) { error('Select the words whose size you want to change.'); return false; }
            document.execCommand(command);
            return true;
          }
          if (!sizing && !['bold','italic','underline','strikeThrough'].includes(command)) {
            error('This formatting command is unavailable for imported layouts.'); return false;
          }
          const parts = markers.filter(node => range.intersectsNode(node)).flatMap(node => {
            const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
            const pieces = [];
            let text;
            while ((text = walker.nextNode())) {
              if (!range.intersectsNode(text)) continue;
              const part = document.createRange(); part.selectNodeContents(text);
              if (text === range.startContainer) part.setStart(text, range.startOffset);
              if (text === range.endContainer) part.setEnd(text, range.endOffset);
              const size = command === 'size' ? value : parseFloat(getComputedStyle(text.parentElement).fontSize) + value;
              if (!part.collapsed) pieces.push({part, size});
            }
            return pieces;
          });
          if (sizing && parts.some(item => !Number.isFinite(item.size) || item.size < 1 || item.size > 512)) {
            error('Choose text sizes between 1 and 512 points.'); return false;
          }
          const previousContent = snapshot();
          suppress = true;
          try {
            for (const {part, size} of parts.reverse()) {
              selection().removeAllRanges(); selection().addRange(part);
              if (sizing) {
                const wrapper = document.createElement('span'); wrapper.style.fontSize = size + 'px';
                wrapper.append(part.cloneContents());
                if (!document.execCommand('insertHTML', false, wrapper.outerHTML)) throw new Error('The selected text could not be formatted.');
              } else if (document.queryCommandState(command) !== applyTrait && !document.execCommand(command)) {
                throw new Error('The selected text could not be formatted.');
              }
            }
          } catch (failure) {
            previousContent.forEach((html, id) => { markers.find(node => node.dataset.ceraltoEdit === id).innerHTML = html; });
            error(failure.message);
          } finally { suppress = false; }
          restoreBookmark(previousSelection);
          notify('Format Text');
          return true;
        }
      };
      window.ceraltoEditor.setEnabled(true);
      post({canUndo: false, canRedo: false, size: ''});
    })();
    """#
}

final class NoteDocumentWebView: WKWebView {
    weak var importedActions: ImportedTextActions?

    @objc func undo(_ sender: Any?) { importedActions?.perform("undo") }
    @objc func redo(_ sender: Any?) { importedActions?.perform("redo") }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return importedActions?.ready == true && importedActions?.canUndo == true }
        if item.action == #selector(redo(_:)) { return importedActions?.ready == true && importedActions?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let actions = importedActions, actions.ready, let focused = window?.firstResponder as? NSView,
              focused === self || focused.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "z", "Z": actions.perform("redo")
            case ".", ">": actions.perform("adjustSize", value: 1)
            case ",", "<": actions.perform("adjustSize", value: -1)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": actions.perform("undo")
            case "b": actions.perform("bold")
            case "i": actions.perform("italic")
            case "u": actions.perform("underline")
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
