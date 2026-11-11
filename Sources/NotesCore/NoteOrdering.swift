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

public struct NoteDateSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let notes: [Note]

    public static func grouping(_ notes: [Note], ordering: NoteOrdering,
                                now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let week = calendar.date(byAdding: .day, value: -7, to: today),
              let month = calendar.date(byAdding: .day, value: -30, to: today) else {
            return [Self(id: "date-error", title: "Date grouping unavailable", notes: notes.sorted(by: ordering.precedes))]
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var groups: [Date: (title: String, notes: [Note])] = [:]
        var invalid: [Note] = []
        for note in notes where !note.isPinned {
            let date = ordering.field == .created ? note.createdAt : note.updatedAt
            guard date.timeIntervalSinceReferenceDate.isFinite else { invalid.append(note); continue }
            let boundary: Date
            let title: String
            if date >= tomorrow { boundary = tomorrow; title = "Future" }
            else if date >= today { boundary = today; title = "Today" }
            else if date >= yesterday { boundary = yesterday; title = "Yesterday" }
            else if date >= week { boundary = week; title = "Previous 7 Days" }
            else if date >= month { boundary = month; title = "Previous 30 Days" }
            else if let interval = calendar.dateInterval(of: .month, for: date) {
                boundary = interval.start
                title = formatter.string(from: date)
            } else {
                invalid.append(note)
                continue
            }
            groups[boundary, default: (title, [])].notes.append(note)
        }
        let ascending = ordering.field != .title && ordering.ascending
        var sections = groups.sorted { ascending ? $0.key < $1.key : $0.key > $1.key }.map { date, group in
            Self(id: String(date.timeIntervalSinceReferenceDate), title: group.title,
                 notes: group.notes.sorted(by: ordering.precedes))
        }
        let pinned = notes.filter(\.isPinned).sorted(by: ordering.precedes)
        if !pinned.isEmpty { sections.insert(Self(id: "pinned", title: "Pinned", notes: pinned), at: 0) }
        if !invalid.isEmpty { sections.append(Self(id: "invalid-dates", title: "Invalid Date", notes: invalid)) }
        return sections
    }
}
