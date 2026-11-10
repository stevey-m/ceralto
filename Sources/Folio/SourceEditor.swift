import AppKit
import NotesCore
import SwiftUI

final class SourceTextView: DocumentTextView {}

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let family: ReadingFont
    let size: Double
    let dracula: Bool
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
        editor.textContainerInset = NSSize(width: 20, height: 20)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Note source editor")
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SourceTextView else { return }
        context.coordinator.parent = self
        if editor.string != text {
            let range = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(range.location, editor.string.utf16.count), length: 0))
            editor.undoManager?.removeAllActions()
        }
        editor.font = NativePageCodec.font(family, size: size)
        editor.textColor = dracula ? NSColor(red: 248 / 255, green: 248 / 255, blue: 242 / 255, alpha: 1) : .textColor
        editor.insertionPointColor = editor.textColor ?? .textColor
        editor.isEditable = isEnabled
        editor.isSelectable = isEnabled
        if !isEnabled, editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        init(parent: SourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? SourceTextView else { return }
            parent.text = editor.string
        }
    }
}
