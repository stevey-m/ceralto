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
                actions.ready = false
                web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
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
        } catch { onError("Could not open this imported note for editing: \(error.localizedDescription)") }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        for name in ["folioImage", "ceraltoEdit"] {
            web.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .defaultClient)
        }
        coordinator.parent.actions.ready = false
        coordinator.parent.actions.webView = nil
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
        lazy var resourceCoordinator = DocumentWebView.Coordinator(parent: documentParent)

        var documentParent: DocumentWebView {
            DocumentWebView(html: "", resources: parent.resources, onImage: parent.onImage,
                onError: parent.onError, onNote: parent.onNote, onLoaded: { [weak self] web in
                    guard let self else { return }
                    self.parent.actions.ready = true
                    self.run(web, script: "window.ceraltoEditor?.setEnabled(enabled);",
                             arguments: ["enabled": self.parent.enabled])
                })
        }

        init(parent: PreservedDocumentView) { self.parent = parent }

        func run(_ web: WKWebView, script: String, arguments: [String: Any] = [:]) {
            Task { @MainActor in
                do {
                    _ = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
                } catch { parent.onError("The imported editor could not update: \(error.localizedDescription)") }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any] else { return }
            if let error = data["error"] as? String { parent.onError(error); return }
            if let size = data["size"] as? String { parent.actions.selectedSize = size }
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
      const post = data => window.webkit.messageHandlers.ceraltoEdit.postMessage(data);
      const markerFor = node => (node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement)?.closest(selector);
      const selection = () => window.getSelection();
      const error = text => post({error: text});
      const normalize = node => {
        const clone = node.cloneNode(true);
        clone.querySelectorAll('[class]').forEach(item => item.removeAttribute('class'));
        // WebKit ends an editing host with a caret placeholder, not a stored line break.
        if (clone.lastChild?.nodeName === 'BR') clone.lastChild.remove();
        return clone.innerHTML;
      };
      function notify() {
        if (suppress) return;
        const changes = {};
        markers.forEach(node => {
          if (node.innerHTML !== originals.get(node.dataset.ceraltoEdit)) {
            changes[node.dataset.ceraltoEdit] = normalize(node);
          }
        });
        sequence += 1;
        pending.set(sequence, new Map(markers.map(node => [node.dataset.ceraltoEdit, node.innerHTML])));
        post({changes, sequence});
      }
      function restoreRange() {
        if (!savedRange || !savedRange.commonAncestorContainer.isConnected) return false;
        selection().removeAllRanges(); selection().addRange(savedRange);
        return true;
      }
      function replaceSections(range, text) {
        const first = markerFor(range.startContainer), last = markerFor(range.endContainer);
        if (!first || !last) { error('Keep the selection inside editable text. Use Source to restructure the layout.'); return; }
        const parts = markers.filter(node => range.intersectsNode(node)).map(node => {
          const part = document.createRange(); part.selectNodeContents(node);
          if (node === first) part.setStart(range.startContainer, range.startOffset);
          if (node === last) part.setEnd(range.endContainer, range.endOffset);
          return part;
        });
        const previous = new Map(markers.map(node => [node, node.innerHTML]));
        suppress = true;
        try {
          for (let index = parts.length - 1; index >= 0; index--) {
            selection().removeAllRanges(); selection().addRange(parts[index]);
            const inserted = index === 0 ? text : '';
            if (!document.execCommand(inserted ? 'insertText' : 'delete', false, inserted)) {
              throw new Error('The selected text could not be replaced.');
            }
          }
          if (selection().rangeCount) savedRange = selection().getRangeAt(0).cloneRange();
        } catch (failure) {
          previous.forEach((html, node) => { node.innerHTML = html; });
          savedRange = null;
          error(failure.message);
        } finally { suppress = false; }
        notify();
      }
      document.addEventListener('selectionchange', () => {
        const current = selection();
        if (!current.rangeCount) return;
        const range = current.getRangeAt(0);
        if (!markerFor(range.startContainer) || !markerFor(range.endContainer)) return;
        savedRange = range.cloneRange();
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
        if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') return;
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
          event.preventDefault(); document.execCommand('insertLineBreak'); notify();
        }
      }, true);
      document.addEventListener('input', notify);
      document.addEventListener('paste', event => {
        if (!markerFor(event.target)) return;
        event.preventDefault();
        const data = event.clipboardData;
        if (data.files.length) { error('Use Add Attachments to insert files or images.'); return; }
        const range = selection().rangeCount ? selection().getRangeAt(0) : null;
        if (range && markerFor(range.startContainer) !== markerFor(range.endContainer)) {
          replaceSections(range.cloneRange(), data.getData('text/plain')); return;
        }
        document.execCommand('insertText', false, data.getData('text/plain'));
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
          suppress = false;
        },
        command(command, value) {
          if (!enabled || !restoreRange()) { error('Select text in the note before formatting it.'); return false; }
          const range = selection().getRangeAt(0);
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
          const first = markerFor(range.startContainer), last = markerFor(range.endContainer);
          const offset = (host, node, position) => {
            const prefix = document.createRange(); prefix.selectNodeContents(host); prefix.setEnd(node, position);
            return prefix.toString().length;
          };
          const startOffset = offset(first, range.startContainer, range.startOffset);
          const endOffset = offset(last, range.endContainer, range.endOffset);
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
          suppress = true;
          try {
            for (const {part, size} of parts.reverse()) {
              selection().removeAllRanges(); selection().addRange(part);
              if (sizing) {
                const wrapper = document.createElement('span'); wrapper.style.fontSize = size + 'px';
                wrapper.append(part.cloneContents());
                document.execCommand('insertHTML', false, wrapper.outerHTML);
              } else if (document.queryCommandState(command) !== applyTrait) document.execCommand(command);
            }
          } finally { suppress = false; }
          const position = (host, count) => {
            const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode())) {
              if (count <= text.length) return [text, count];
              count -= text.length;
            }
            return [host, host.childNodes.length];
          };
          const restored = document.createRange();
          restored.setStart(...position(first, startOffset)); restored.setEnd(...position(last, endOffset));
          selection().removeAllRanges(); selection().addRange(restored); savedRange = restored.cloneRange();
          notify();
          return true;
        }
      };
      window.ceraltoEditor.setEnabled(true);
    })();
    """#
}

final class NoteDocumentWebView: WKWebView {
    weak var importedActions: ImportedTextActions?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let actions = importedActions, actions.ready, let focused = window?.firstResponder as? NSView,
              focused === self || focused.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case ".", ">": actions.perform("adjustSize", value: 1)
            case ",", "<": actions.perform("adjustSize", value: -1)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
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
