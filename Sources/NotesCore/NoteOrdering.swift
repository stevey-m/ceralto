import Foundation

public enum NoteSortField: String, Codable, CaseIterable, Sendable {
    case updated = "Last edited", created = "Date created", title = "Title"
}

public struct NoteOrdering: Codable, Equatable, Sendable {
    public var version = 1
    public var field: NoteSortField
    public var ascending: Bool

    public init(field: NoteSortField = .updated, ascending: Bool = false) {
        self.field = field
        self.ascending = ascending
    }

    public func validate() throws {
        guard version == 1 else { throw NoteWorkflowError("Unsupported note-order settings.") }
    }

    public func precedes(_ first: Note, _ second: Note) -> Bool {
        if first.isPinned != second.isPinned { return first.isPinned }
        let comparison: ComparisonResult
        switch field {
        case .title:
            comparison = first.displayTitle.localizedStandardCompare(second.displayTitle)
        case .created:
            comparison = first.createdAt.compare(second.createdAt)
        case .updated:
            comparison = first.updatedAt.compare(second.updatedAt)
        }
        if comparison == .orderedSame { return first.id.uuidString < second.id.uuidString }
        return comparison == (ascending ? .orderedAscending : .orderedDescending)
    }
}

public enum BulkNoteAction: Sendable {
    case move(UUID), addTags([String]), trash, restore
}
