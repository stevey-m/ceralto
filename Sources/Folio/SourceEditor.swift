import AppKit
import NotesCore
import SwiftUI

final class SourceTextView: DocumentTextView {
    var focusOnAttach = false
    var tabStyle = SourceTabStyle.native

    override func insertTab(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), tabStyle != .native else { super.insertTab(sender); return }
        insertText(tabStyle.insertion, replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        suppressAutomaticEditing = true
        defer { suppressAutomaticEditing = false }
        super.paste(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isEditable else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

@MainActor
final class SourceLineRuler: NSRulerView {
    private(set) var lineStarts = [0]
    private var cachedText: String?

    init(scroll: NSScrollView, editor: SourceTextView) {
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 42
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    func refresh() {
        guard let editor = clientView as? SourceTextView else { return }
        if cachedText != editor.string {
            cachedText = editor.string
            let body = editor.string as NSString
            lineStarts = [0]
            var index = 0
            while index < body.length {
                var end = 0, contentsEnd = 0
                body.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
                if end < body.length || contentsEnd < end { lineStarts.append(end) }
                index = end
            }
        }
        let digits = String(lineStarts.count).count
        ruleThickness = max(42, CGFloat(digits) * 10 + 16)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = clientView as? SourceTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, min(16, (editor.font?.pointSize ?? 14) * 0.8)), weight: .regular),
            .foregroundColor: (editor.textColor ?? .secondaryLabelColor).withAlphaComponent(0.55)
        ]
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] < characters.location { low = mid + 1 } else { high = mid }
        }
        for index in max(0, low - 1)..<lineStarts.count {
            let position = lineStarts[index]
            if position > characters.upperBound { break }
            let lineRect: NSRect
            if position == editor.string.utf16.count {
                lineRect = layout.extraLineFragmentRect
            } else {
                lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
            }
            let point = editor.convert(NSPoint(x: origin.x, y: origin.y + lineRect.minY), to: self)
            let label = String(index + 1) as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attrs).width - 7, y: point.y),
                       withAttributes: attrs)
        }
    }
}

struct SourceEditor: NSViewRepresentable {
    @AppStorage("editorPairDelimiters") private var pairDelimiters = false
    @AppStorage("sourceTabStyle") private var tabStyle = SourceTabStyle.native.rawValue
    @AppStorage("sourceLineNumbers") private var lineNumbers = false
    @AppStorage("writingColumnWidth") private var columnWidth = 0
    @Binding var text: String
    let family: ReadingFont
    let size: Double
    let dracula: Bool
    let currentSource: () -> String
    var accessibilityLabel = "Note source editor"
    var textInset = NSSize(width: 20, height: 20)
    var focusOnAttach = false
    var usesWritingPreferences = true
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = SourceTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = textInset
        editor.focusOnAttach = focusOnAttach
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SourceTextView else { return }
        context.coordinator.parent = self
        let latestText = currentSource()
        if editor.string != latestText {
            let range = editor.selectedRange()
            editor.string = latestText
            editor.setSelectedRange(NSRange(location: min(range.location, editor.string.utf16.count), length: 0))
            editor.undoManager?.removeAllActions()
        }
        let font = NativePageCodec.font(family, size: size)
        if editor.font != font { editor.font = font }
        let color = dracula ? NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1) : .textColor
        if editor.textColor != color { editor.textColor = color }
        editor.insertionPointColor = editor.textColor ?? .textColor
        editor.pairDelimiters = usesWritingPreferences && pairDelimiters
        editor.tabStyle = usesWritingPreferences ? (SourceTabStyle(rawValue: tabStyle) ?? .native) : .native
        editor.configureWritingWidth(usesWritingPreferences ? CGFloat(columnWidth) : 0, inset: textInset)
        let showNumbers = usesWritingPreferences && lineNumbers
        if showNumbers, scroll.verticalRulerView == nil {
            scroll.verticalRulerView = SourceLineRuler(scroll: scroll, editor: editor)
            scroll.hasVerticalRuler = true
        }
        scroll.rulersVisible = showNumbers
        (scroll.verticalRulerView as? SourceLineRuler)?.refresh()
        FolioPalette.style(editor, dracula: dracula)
        if editor.isEditable != isEnabled { editor.isEditable = isEnabled }
        if editor.isSelectable != isEnabled { editor.isSelectable = isEnabled }
        if !isEnabled, editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        init(parent: SourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SourceTextView else { return }
            parent.text = editor.string
            (editor.enclosingScrollView?.verticalRulerView as? SourceLineRuler)?.refresh()
        }
    }
}
