import Foundation

public struct NoteTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let title: String
    public let body: String
    public let tags: [String]?

    public func render(_ text: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return text.replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: date.formatted(date: .omitted, time: .shortened))
    }
}

public struct NoteExtension: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let apiVersion: Int
    public let templates: [NoteTemplate]
}

public enum NoteExtensions {
    public static func load(from directory: URL) throws -> [NoteExtension] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        var result: [NoteExtension] = []
        for folder in try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw JoplinImportError.invalid("Extensions must be folders, not files or symbolic links: \(folder.lastPathComponent)")
            }
            let manifest = folder.appendingPathComponent("extension.json")
            guard try manifest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw JoplinImportError.invalid("Extension manifests cannot be symbolic links.")
            }
            let pack = try JSONDecoder().decode(NoteExtension.self, from: Data(contentsOf: manifest))
            guard pack.apiVersion == 1, validID(pack.id), !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.templates.isEmpty, Set(pack.templates.map(\.id)).count == pack.templates.count,
                  pack.templates.allSatisfy({ validID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  !result.contains(where: { $0.id == pack.id }) else {
                throw JoplinImportError.invalid("Invalid or unsupported extension: \(folder.lastPathComponent). Folio supports template API version 1.")
            }
            result.append(pack)
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
        }
    }
}
