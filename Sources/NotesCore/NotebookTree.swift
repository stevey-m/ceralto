import Foundation

public struct NotebookBranch: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let notebooks: [Notebook]
    public let descendants: [UUID]
    public let children: [NotebookBranch]

    public static func build(_ notebooks: [Notebook]) -> [NotebookBranch] {
        build(notebooks.map { (notebook: $0, parts: $0.name.split(separator: "/").map(String.init)) }, prefix: "")
    }

    private static func build(_ entries: [(notebook: Notebook, parts: [String])], prefix: String) -> [NotebookBranch] {
        let grouped = Dictionary(grouping: entries) { $0.parts.first ?? $0.notebook.name }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let group = grouped[name] ?? []
            let path = prefix.isEmpty ? name : prefix + "/" + name
            return NotebookBranch(
                id: path, name: name,
                notebooks: group.filter { $0.parts.count <= 1 }.map(\.notebook),
                descendants: group.map(\.notebook.id),
                children: build(group.filter { $0.parts.count > 1 }.map {
                    (notebook: $0.notebook, parts: Array($0.parts.dropFirst()))
                }, prefix: path)
            )
        }
    }
}
