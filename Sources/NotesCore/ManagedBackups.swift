import CryptoKit
import Foundation

public struct ManagedBackup: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let folder: URL
    public let notes: Int
    public let notebooks: Int
}

public enum ManagedBackups {
    private struct Receipt: Codable {
        let version: Int
        let owner: UUID
        let id: UUID
        let date: Date
        let hashes: [String: String]
    }

    public static func directory(in parent: URL, owner: UUID) -> URL {
        parent.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("Deltos Backups", isDirectory: true)
            .appendingPathComponent(owner.uuidString, isDirectory: true)
    }

    public static func create(_ library: Library, in parent: URL, owner: UUID,
                              date: Date = Date()) throws -> ManagedBackup {
        try coordinatedWrite(parent) { try createUncoordinated(library, in: $0, owner: owner, date: date) }
    }

    private static func createUncoordinated(_ library: Library, in parent: URL, owner: UUID,
                                           date: Date) throws -> ManagedBackup {
        let manager = FileManager.default
        try requireDirectory(parent.standardizedFileURL.resolvingSymlinksInPath())
        let root = directory(in: parent, owner: owner)
        if !manager.fileExists(atPath: root.deletingLastPathComponent().path) {
            try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: false)
        }
        try requireDirectory(root.deletingLastPathComponent())
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try requireDirectory(root)
        let id = UUID()
        let staging = root.appendingPathComponent(".incomplete-" + id.uuidString)
        let destination = root.appendingPathComponent(id.uuidString)
        try LibraryBackup.export(library, to: staging)
        do {
            let receipt = Receipt(version: 1, owner: owner, id: id, date: date, hashes: try hashes(in: staging))
            try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("backup-receipt.json"), options: .atomic)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            if manager.fileExists(atPath: staging.path) { try JoplinImport.discardSnapshot(staging, after: error) }
            throw error
        }
        return try inspect(destination, owner: owner)
    }

    public static func list(in parent: URL, owner: UUID) throws -> [ManagedBackup] {
        let root = directory(in: parent, owner: owner)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try requireDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try inspect($0, owner: owner) }
            .sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }

    public static func inspect(_ folder: URL, owner: UUID) throws -> ManagedBackup {
        let receipt = try verifiedReceipt(in: folder)
        guard receipt.owner == owner, receipt.id.uuidString == folder.lastPathComponent,
              let library = try LibraryStorage(url: folder.appendingPathComponent("library.json")).load() else {
            throw JoplinImportError.invalid("This managed backup belongs to another backup set.")
        }
        return ManagedBackup(id: receipt.id, date: receipt.date, folder: folder,
                             notes: library.notes.count, notebooks: library.notebooks.count)
    }

    static func verifyPortableCopy(_ folder: URL) throws {
        _ = try verifiedReceipt(in: folder)
    }

    private static func verifiedReceipt(in folder: URL) throws -> Receipt {
        try requireDirectory(folder)
        let url = folder.appendingPathComponent("backup-receipt.json")
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw JoplinImportError.invalid("A backup receipt cannot be a symbolic link.")
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard receipt.version == 1, receipt.hashes == (try hashes(in: folder)) else {
            throw JoplinImportError.invalid("This managed backup is incomplete or damaged.")
        }
        return receipt
    }

    public static func prune(in parent: URL, owner: UUID, keeping count: Int) throws {
        guard (1...100).contains(count) else { throw JoplinImportError.invalid("Keep between 1 and 100 managed backups.") }
        try coordinatedWrite(parent) { coordinated in
            let backups = try list(in: coordinated, owner: owner)
            for backup in backups.dropFirst(count) {
                _ = try inspect(backup.folder, owner: owner)
                try FileManager.default.removeItem(at: backup.folder)
            }
        }
    }

    private static func coordinatedWrite<Value>(_ parent: URL, operation: (URL) throws -> Value) throws -> Value {
        var coordinationError: NSError?
        var outcome: Result<Value, Error>?
        NSFileCoordinator().coordinate(writingItemAt: parent, options: .forMerging, error: &coordinationError) { coordinated in
            outcome = Result { try operation(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw JoplinImportError.invalid("The backup folder could not be coordinated.") }
        return try outcome.get()
    }

    private static func requireDirectory(_ folder: URL) throws {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw JoplinImportError.invalid("Managed backups must use real directories, not symbolic links.")
        }
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == folder.standardizedFileURL.path else {
            throw JoplinImportError.invalid("The managed backup path must not traverse symbolic links.")
        }
    }

    private static func hashes(in folder: URL) throws -> [String: String] {
        let prefix = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw JoplinImportError.invalid("The backup could not be enumerated.")
        }
        if let enumerationError { throw enumerationError }
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw JoplinImportError.invalid("Backups cannot contain symbolic links.") }
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { throw JoplinImportError.invalid("A backup file is outside its directory.") }
            let relative = String(path.dropFirst(prefix.count))
            if relative == "backup-receipt.json" { continue }
            let handle = try FileHandle(forReadingFrom: file)
            var digest = SHA256()
            do {
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            result[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard result["library.json"] != nil else { throw JoplinImportError.invalid("The backup has no library file.") }
        return result
    }
}
