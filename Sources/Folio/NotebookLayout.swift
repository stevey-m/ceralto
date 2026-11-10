import AppKit
import NotesCore
import SwiftUI

struct NotebookLayout<Notebooks: View, Notes: View, Document: View>: View {
    let showNotebooks: Bool
    let showNotes: Bool
    @ViewBuilder let notebooks: () -> Notebooks
    @ViewBuilder let notes: () -> Notes
    @ViewBuilder let document: () -> Document
    @AppStorage("notebookPaneWidth") private var notebookWidth = 220.0
    @AppStorage("noteListPaneWidth") private var noteWidth = 250.0
    @ViewState private var notebookDragStart: Double?
    @ViewState private var noteDragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let widths = PaneWidths(available: geometry.size.width, notebooks: notebookWidth,
                                    notes: noteWidth, showNotebooks: showNotebooks, showNotes: showNotes)
            HStack(spacing: 0) {
                if showNotebooks {
                    notebooks()
                        .frame(width: widths.notebooks, height: geometry.size.height)
                        .clipped()
                    resizeHandle(label: "Notebook column width", value: widths.notebooks) { delta, ended in
                        let start = notebookDragStart ?? widths.notebooks
                        notebookDragStart = start
                        let minimumDocument = min(520.0, max(400.0, geometry.size.width - 296))
                        let maximum = geometry.size.width - minimumDocument - widths.notes
                            - (showNotes ? 16 : 8)
                        notebookWidth = min(max(120, start + delta), max(120, maximum))
                        if ended { notebookDragStart = nil }
                    } adjust: { direction in
                        notebookWidth = max(120, widths.notebooks + direction * 20)
                    }
                }
                if showNotes {
                    notes()
                        .frame(width: widths.notes, height: geometry.size.height)
                        .clipped()
                    resizeHandle(label: "Note list column width", value: widths.notes) { delta, ended in
                        let start = noteDragStart ?? widths.notes
                        noteDragStart = start
                        let minimumDocument = min(520.0, max(400.0, geometry.size.width - 296))
                        let maximum = geometry.size.width - widths.notebooks - minimumDocument
                            - (showNotebooks ? 16 : 8)
                        noteWidth = min(max(160, start + delta), max(160, maximum))
                        if ended { noteDragStart = nil }
                    } adjust: { direction in
                        noteWidth = max(160, widths.notes + direction * 20)
                    }
                }
                document()
                    .frame(width: widths.document, height: geometry.size.height)
                    .clipped()
            }
        }
    }

    private func resizeHandle(label: String, value: Double,
                              drag: @escaping (Double, Bool) -> Void,
                              adjust: @escaping (Double) -> Void) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: PaneWidths.divider)
            .overlay { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag($0.translation.width, false) }
                .onEnded { drag($0.translation.width, true) })
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(1)
                case .decrement: adjust(-1)
                @unknown default: break
                }
            }
    }
}
