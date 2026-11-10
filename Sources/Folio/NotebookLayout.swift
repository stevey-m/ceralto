import AppKit
import NotesCore
import SwiftUI

struct ReferenceLayout<Primary: View, Reference: View>: View {
    let showReference: Bool
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let reference: () -> Reference
    @AppStorage("referencePaneFraction") private var fraction = 0.45
    @ViewState private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - PaneWidths.divider)
            let minimum = min(130.0, available / 2)
            let referenceWidth = min(max(available * fraction, minimum), available - minimum)
            HStack(spacing: 0) {
                primary()
                    .frame(width: showReference ? available - referenceWidth : geometry.size.width,
                           height: geometry.size.height)
                    .clipped()
                if showReference {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: PaneWidths.divider)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? referenceWidth
                                dragStart = start
                                fraction = min(max((start - value.translation.width) / max(1, available), 0.2), 0.8)
                            }
                            .onEnded { _ in dragStart = nil })
                        .accessibilityLabel("Reference pane width")
                        .accessibilityValue("\(Int(referenceWidth)) points")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: fraction = min(0.8, fraction + 0.05)
                            case .decrement: fraction = max(0.2, fraction - 0.05)
                            @unknown default: break
                            }
                        }
                    reference()
                        .frame(width: referenceWidth, height: geometry.size.height)
                        .clipped()
                }
            }
        }
    }
}

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
