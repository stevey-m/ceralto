import SwiftUI

enum SourceTabStyle: String, CaseIterable {
    case native = "Tab character", twoSpaces = "Two spaces", fourSpaces = "Four spaces"

    var insertion: String {
        switch self {
        case .native: "\t"
        case .twoSpaces: "  "
        case .fourSpaces: "    "
        }
    }
}

struct EditorPreferenceControls: View {
    @AppStorage("editorPairDelimiters") private var pairDelimiters = false
    @AppStorage("composeMarkdownShortcuts") private var markdownShortcuts = false
    @AppStorage("sourceTabStyle") private var tabStyle = SourceTabStyle.native.rawValue
    @AppStorage("sourceLineNumbers") private var lineNumbers = false
    @AppStorage("writingColumnWidth") private var columnWidth = 0

    var body: some View {
        Toggle("Pair brackets and quotes while typing", isOn: $pairDelimiters)
        Toggle("Markdown block shortcuts in Compose", isOn: $markdownShortcuts)
        Text("Type #, ##, >, -, *, 1. or - [ ] followed by a space at the start of a plain paragraph to format it. Paste and code blocks are unchanged.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Tab in Markdown source", selection: $tabStyle) {
            ForEach(SourceTabStyle.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
        }
        Toggle("Show Markdown source line numbers", isOn: $lineNumbers)
        Picker("Writing column", selection: $columnWidth) {
            Text("Full available width").tag(0)
            Text("Comfortable (720 pt)").tag(720)
            Text("Wide (900 pt)").tag(900)
        }
        Text("Writing width applies to Compose and Markdown source, not Quick Capture. Line numbers count source lines, not wrapped display lines.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
