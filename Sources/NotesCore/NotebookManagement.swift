import Foundation

public enum NotebookManagement {
    public static func validatedPath(_ input: String) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) &&
            $0.rangeOfCharacter(from: .controlCharacters) == nil && !$0.contains("\\")
        }) else { throw NoteWorkflowError("Use nonempty folder names separated by /, without . or .. segments.") }
        return path
    }

    public static func renaming(_ library: Library, branch: String, to input: String) throws -> Library {
        let destination = try validatedPath(input)
        let moving = library.notebooks.filter { $0.name == branch || $0.name.hasPrefix(branch + "/") }
        guard !moving.isEmpty else { throw NoteWorkflowError("That notebook branch no longer exists.") }
        guard destination != branch else { return library }
        guard !destination.hasPrefix(branch + "/") else {
            throw NoteWorkflowError("A notebook cannot be moved inside itself or one of its subfolders.")
        }
        let occupied = library.notebooks.filter { notebook in !moving.contains { $0.id == notebook.id } }
        let destinationKey = destination.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard !occupied.contains(where: {
            let key = $0.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return key == destinationKey || key.hasPrefix(destinationKey + "/")
        }) else { throw NoteWorkflowError("A notebook branch already exists at that destination. Nothing was merged or moved.") }
        var result = library
        let ids = Set(moving.map(\.id))
        for index in result.notebooks.indices where ids.contains(result.notebooks[index].id) {
            result.notebooks[index].name = destination + String(result.notebooks[index].name.dropFirst(branch.count))
        }
        try result.validate()
        return result
    }

    public static func movingNotes(_ ids: Set<UUID>, in library: Library, to input: String) throws -> Library {
        let path = try validatedPath(input)
        guard !ids.isEmpty, ids.allSatisfy({ id in library.notes.contains { $0.id == id && $0.deletedAt == nil } }) else {
            throw NoteWorkflowError("Only existing, active notes can be moved.")
        }
        var result = library
        let matches = result.notebooks.filter { $0.name == path }
        guard matches.count <= 1 else { throw NoteWorkflowError("This path has duplicate imported notebooks. Choose a unique destination.") }
        let notebook = matches.first ?? Notebook(name: path)
        if matches.isEmpty { result.notebooks.append(notebook) }
        for index in result.notes.indices where ids.contains(result.notes[index].id) {
            result.notes[index].notebookID = notebook.id
        }
        try result.validate()
        return result
    }
}
