import AppKit
import NotesCore
import SwiftUI

enum NoteListSpacing: String, CaseIterable {
    case compact = "Compact", comfortable = "Comfortable", spacious = "Spacious"

    var padding: CGFloat {
        switch self {
        case .compact: 4
        case .comfortable: 10
        case .spacious: 16
        }
    }
}

enum GallerySelection {
    static func selecting(_ id: UUID, in ordered: [UUID], current: Set<UUID>, anchor: UUID?,
                          extending: Bool, toggling: Bool) -> Set<UUID> {
        let visible = current.intersection(ordered)
        guard let index = ordered.firstIndex(of: id) else { return visible }
        if extending, let anchor, let start = ordered.firstIndex(of: anchor) {
            let range = Set(ordered[min(start, index)...max(start, index)])
            return toggling ? visible.union(range) : range
        }
        if toggling {
            return visible.contains(id) ? visible.subtracting([id]) : visible.union([id])
        }
        return [id]
    }
}

struct NoteGallery<Content: View>: View {
    let notes: [Note]
    let sections: [NoteDateSection]
    @Binding var selection: Set<UUID>
    let onActivate: (UUID) -> Void
    @ViewBuilder let content: (Note) -> Content
    @ViewState private var anchor: UUID?
    @FocusState private var focusedNote: UUID?
    @ThemeColors private var palette

    private var orderedIDs: [UUID] {
        (sections.isEmpty ? notes : sections.flatMap(\.notes)).map(\.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let minimum = min(180, max(120, geometry.size.width - 24))
            let columns = max(1, Int((geometry.size.width - 12) / (minimum + 12)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if sections.isEmpty {
                        cards(notes, minimum: minimum, columns: columns)
                    } else {
                        ForEach(sections) { section in
                            Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                            cards(section.notes, minimum: minimum, columns: columns)
                        }
                    }
                }
                .padding(12)
            }
        }
        .accessibilityLabel("Note gallery")
    }

    private func cards(_ notes: [Note], minimum: CGFloat, columns: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12)], spacing: 12) {
            ForEach(notes) { note in
                Button {
                    let flags = NSApp.currentEvent?.modifierFlags ?? []
                    activate(note.id, extending: flags.contains(.shift), toggling: flags.contains(.command))
                } label: {
                    content(note)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(palette?.sidebarColor ?? Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selection.contains(note.id) ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: selection.contains(note.id) ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedNote, equals: note.id)
                .accessibilityIdentifier("deltos-gallery-note-\(note.id)")
                .accessibilityAddTraits(selection.contains(note.id) ? .isSelected : [])
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard let index = orderedIDs.firstIndex(of: note.id) else { return .ignored }
                    let offset = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 :
                        press.key == .upArrow ? -columns : columns
                    let target = orderedIDs[min(max(0, index + offset), orderedIDs.count - 1)]
                    activate(target, extending: press.modifiers.contains(.shift), toggling: false)
                    return .handled
                }
            }
        }
    }

    private func activate(_ id: UUID, extending: Bool, toggling: Bool) {
        selection = GallerySelection.selecting(id, in: orderedIDs, current: selection, anchor: anchor,
                                               extending: extending, toggling: toggling)
        if !extending { anchor = id }
        focusedNote = id
        if selection.contains(id) { onActivate(id) }
    }
}
