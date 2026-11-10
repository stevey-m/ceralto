import Foundation

extension LibraryStorage {
    public var recoveryDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Keep the first validated on-disk library from each of the last seven opening days.
    public func prepareRecoveryCopy(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let library = try JSONDecoder().decode(Library.self, from: data)
        try library.validate()
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let date = String(now.ISO8601Format().prefix(10))
        let destination = recoveryDirectory.appendingPathComponent("library-\(date).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = LibraryStorage(url: destination)
            _ = try existing.load()
        } else {
            try data.write(to: destination, options: .atomic)
        }
        let copies = try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^library-\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for copy in copies.dropFirst(7) { try FileManager.default.removeItem(at: copy) }
    }
}
