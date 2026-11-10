import Foundation

public struct NoteTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let title: String
    public let body: String
    public let tags: [String]?

    public init(id: String, name: String, title: String, body: String, tags: [String]? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.body = body
        self.tags = tags
    }

    public func render(_ text: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return text.replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: date.formatted(date: .omitted, time: .shortened))
    }
}

public struct TemplateChoice: Identifiable, Equatable, Sendable {
    public let packID: String
    public let packName: String
    public let template: NoteTemplate
    public var id: String { packID + "/" + template.id }

    public init(packID: String, packName: String, template: NoteTemplate) {
        self.packID = packID
        self.packName = packName
        self.template = template
    }

    public static let builtInPackID = "dev.folio.builtin"
    public static let daily = TemplateChoice(packID: builtInPackID, packName: "Deltos", template:
        NoteTemplate(id: "daily", name: "Daily page", title: "{{date}}",
                     body: "# {{date}}\n\n## Notes\n\n\n## Tasks\n\n", tags: ["daily"]))

    public static let builtIn: [TemplateChoice] = [
        daily,
        TemplateChoice(packID: "dev.folio.builtin", packName: "Deltos", template:
            NoteTemplate(id: "meeting", name: "Meeting notes", title: "Meeting - {{date}}",
                         body: "# Meeting\n\n## Agenda\n\n\n## Notes\n\n\n## Actions\n\n", tags: ["meetings"])),
        TemplateChoice(packID: "dev.folio.builtin", packName: "Deltos", template:
            NoteTemplate(id: "project", name: "Project brief", title: "New project",
                         body: "# Project\n\n## Goal\n\n\n## Next steps\n\n- [ ] Define the next step\n", tags: ["projects"]))
    ]
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
            guard pack.apiVersion == 1, validID(pack.id), pack.id != TemplateChoice.builtInPackID,
                  !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.templates.isEmpty, Set(pack.templates.map(\.id)).count == pack.templates.count,
                  pack.templates.allSatisfy({ validID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  !result.contains(where: { $0.id == pack.id }) else {
                throw JoplinImportError.invalid("Invalid or unsupported extension: \(folder.lastPathComponent). Deltos supports template API version 1.")
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
