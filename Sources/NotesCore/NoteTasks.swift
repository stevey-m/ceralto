import Foundation
import cmark_gfm

public struct NoteWorkflowError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct NoteTask: Identifiable, Equatable, Sendable {
    public var id: String { "\(noteID)/\(lineNumber)/\(markerOffset)" }
    public let noteID: UUID
    public let lineNumber: Int
    public let title: String
    public let isComplete: Bool
    public let sourceLine: String
    fileprivate let markerOffset: Int
}

public enum NoteTasks {
    public static func find(in library: Library) throws -> [NoteTask] {
        try library.notes.filter { $0.deletedAt == nil }.flatMap { try find(in: $0) }
    }

    public static func find(in note: Note) throws -> [NoteTask] {
        guard note.contentFormat != .html else { return [] }
        guard let document = note.body.withCString({
            cmark_parse_document($0, note.body.utf8.count, CMARK_OPT_DEFAULT)
        }) else { throw NoteWorkflowError("Could not parse Markdown tasks in \(note.displayTitle).") }
        defer { cmark_node_free(document) }
        guard let iterator = cmark_iter_new(document) else {
            throw NoteWorkflowError("Could not inspect Markdown tasks in \(note.displayTitle).")
        }
        defer { cmark_iter_free(iterator) }
        let pattern = try NSRegularExpression(
            pattern: #"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\](?:[ \t]+(.*))?\r?$"#)
        let lines = note.body.components(separatedBy: "\n")
        var result: [NoteTask] = []
        var event = cmark_iter_next(iterator)
        while event != CMARK_EVENT_DONE {
            if event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
               String(cString: cmark_node_get_type_string(node)) == "item" {
                let line = Int(cmark_node_get_start_line(node)) - 1
                let column = max(0, Int(cmark_node_get_start_column(node)) - 1)
                if lines.indices.contains(line) {
                    let raw = lines[line]
                    let prefix = String(decoding: raw.utf8.prefix(column), as: UTF8.self)
                    let source = String(decoding: raw.utf8.dropFirst(column), as: UTF8.self) as NSString
                    if let match = pattern.firstMatch(in: source as String, range: NSRange(location: 0, length: source.length)) {
                        let marker = match.range(at: 1)
                        let title = match.range(at: 2)
                        result.append(NoteTask(noteID: note.id, lineNumber: line + 1,
                            title: title.location == NSNotFound ? "" : source.substring(with: title).trimmingCharacters(in: .whitespacesAndNewlines),
                            isComplete: source.substring(with: marker).lowercased() == "x",
                            sourceLine: raw, markerOffset: (prefix as NSString).length + marker.location))
                    }
                }
            }
            event = cmark_iter_next(iterator)
        }
        return result
    }

    public static func setting(_ task: NoteTask, complete: Bool, in note: Note) throws -> String {
        guard task.noteID == note.id, note.deletedAt == nil,
              try find(in: note).contains(where: { $0.id == task.id && $0.sourceLine == task.sourceLine }) else {
            throw NoteWorkflowError("This task changed or moved. Refresh the task list before changing it.")
        }
        var lines = note.body.components(separatedBy: "\n")
        let line = NSMutableString(string: task.sourceLine)
        line.replaceCharacters(in: NSRange(location: task.markerOffset, length: 1), with: complete ? "x" : " ")
        lines[task.lineNumber - 1] = line as String
        return lines.joined(separator: "\n")
    }
}
