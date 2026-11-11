import CryptoKit
import Foundation

public struct SyncClock: Codable, Equatable, Sendable {
    public var counters: [String: Int] = [:]
    public init() {}

    public func dominates(_ other: SyncClock) -> Bool {
        let keys = Set(counters.keys).union(other.counters.keys)
        return keys.allSatisfy { counters[$0, default: 0] >= other.counters[$0, default: 0] } &&
            keys.contains { counters[$0, default: 0] > other.counters[$0, default: 0] }
    }

    mutating func join(_ other: SyncClock) {
        for (key, value) in other.counters { counters[key] = max(counters[key, default: 0], value) }
    }

    mutating func advance(_ device: UUID) { counters[device.uuidString, default: 0] += 1 }
}

public struct FolderSyncState: Codable, Equatable, Sendable {
    public var folderID: UUID
    public var deviceID: UUID
    public var notes: [UUID: SyncClock] = [:]
    public var notebooks: [UUID: SyncClock] = [:]
    public var noteFingerprints: [UUID: String] = [:]
    public var notebookNames: [UUID: String] = [:]
    public var conflictSummaries: [SyncConflictSummary]?

    public init(folderID: UUID, deviceID: UUID = UUID()) {
        self.folderID = folderID
        self.deviceID = deviceID
    }
}

public struct SyncConflictSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var variantIDs: [UUID]
    public var includesDeletion: Bool

    public init(id: UUID, variantIDs: [UUID], includesDeletion: Bool = false) {
        self.id = id
        self.variantIDs = variantIDs
        self.includesDeletion = includesDeletion
    }
}

public struct FolderSyncResult: Sendable {
    public let library: Library
    public let conflicts: Int

    public init(library: Library, conflicts: Int) {
        self.library = library
        self.conflicts = conflicts
    }
}

/// Immutable, checksummed snapshots. Device-local library.json is never shared.
public enum FolderSync {
    private struct Identity: Codable { let version: Int; let id: UUID }
    private struct Commit: Codable {
        let version: Int
        let id: UUID
        let state: FolderSyncState
        let hashes: [String: String]
    }
    private struct Snapshot {
        let commit: Commit
        let library: Library
        let folder: URL
    }
    private struct Candidate {
        let note: Note?
        let clock: SyncClock
        let snapshot: Snapshot
        let fingerprint: String
    }

    public static func synchronize(_ local: Library, folder: URL, assets: URL) throws -> FolderSyncResult {
        try local.validate()
        var coordinationError: NSError?
        var result: Result<FolderSyncResult, Error>?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { coordinated in
            result = Result { try exchange(local, folder: coordinated, assets: assets) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw JoplinImportError.invalid("The shared folder could not be coordinated. Reconnect it and retry.") }
        return try result.get()
    }

    public static func pull(_ local: Library, folder: URL, assets: URL) throws -> FolderSyncResult {
        var coordinationError: NSError?
        var result: Result<FolderSyncResult, Error>?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .withoutChanges, error: &coordinationError) { coordinated in
            result = Result {
                let root = coordinated.appendingPathComponent("Folio Sync", isDirectory: true)
                let identity = try JSONDecoder().decode(Identity.self,
                    from: availableData(at: root.appendingPathComponent("folder.json")))
                guard identity.version == 1 else { throw LibraryError.unsupportedVersion(identity.version) }
                let state = local.folderSync.flatMap { $0.folderID == identity.id ? $0 : nil } ??
                    FolderSyncState(folderID: identity.id)
                let incoming = try snapshots(in: root.appendingPathComponent("snapshots"), folderID: identity.id)
                guard !incoming.isEmpty else {
                    throw JoplinImportError.invalid("Sync this folder from your Mac first, then let your cloud provider download it.")
                }
                    return try merge(incoming, localState: state, assets: assets)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw JoplinImportError.invalid("The shared folder could not be read. Reconnect it and retry.") }
        return try result.get()
    }

    private static func exchange(_ local: Library, folder: URL, assets: URL) throws -> FolderSyncResult {
        let manager = FileManager.default
        let root = folder.appendingPathComponent("Folio Sync", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let identityURL = root.appendingPathComponent("folder.json")
        if manager.fileExists(atPath: root.appendingPathComponent(".folder.json.icloud").path) {
            try manager.startDownloadingUbiquitousItem(at: identityURL)
            throw SyncFailure.unavailable("iCloud is downloading the folder identity. Retry once it is available offline.")
        }
        let identity: Identity
        if manager.fileExists(atPath: identityURL.path) {
            identity = try JSONDecoder().decode(Identity.self, from: availableData(at: identityURL))
            guard identity.version == 1 else { throw LibraryError.unsupportedVersion(identity.version) }
        } else {
            identity = Identity(version: 1, id: UUID())
            try encoded(identity).write(to: identityURL, options: .atomic)
        }
        var state = local.folderSync.flatMap { $0.folderID == identity.id ? $0 : nil } ??
            FolderSyncState(folderID: identity.id)
        let current = Dictionary(uniqueKeysWithValues: local.notes.map { ($0.id, $0) })
        for id in Set(state.notes.keys).union(current.keys) {
            let fingerprint = try current[id].map { try noteFingerprint($0) }
            if fingerprint != state.noteFingerprints[id] || state.notes[id] == nil {
                var clock = state.notes[id] ?? SyncClock()
                clock.advance(state.deviceID)
                state.notes[id] = clock
            }
        }
        let currentNotebooks = Dictionary(uniqueKeysWithValues: local.notebooks.map { ($0.id, $0.name) })
        for id in Set(state.notebooks.keys).union(currentNotebooks.keys) {
            if state.notebookNames[id] != currentNotebooks[id] || state.notebooks[id] == nil {
                var clock = state.notebooks[id] ?? SyncClock()
                clock.advance(state.deviceID)
                state.notebooks[id] = clock
            }
        }
        let commits = root.appendingPathComponent("snapshots", isDirectory: true)
        try manager.createDirectory(at: commits, withIntermediateDirectories: true)
        // A new local version is published only after all of its resources have been copied.
        // The ready marker is written last; receivers verify hashes before using anything.
        let id = UUID()
        let outgoing = commits.appendingPathComponent(id.uuidString, isDirectory: true)
        var portable = local
        portable.folderSync = nil
        try LibraryBackup.export(portable, to: outgoing)
        do {
            let hashes = try fileHashes(in: outgoing)
            let commit = Commit(version: 1, id: id, state: state, hashes: hashes)
            try encoded(commit).write(to: outgoing.appendingPathComponent("ready.json"), options: .atomic)
        } catch {
            try JoplinImport.discardSnapshot(outgoing, after: error)
            throw error
        }
        return try merge(snapshots(in: commits, folderID: identity.id), localState: state, assets: assets)
    }

    private static func snapshots(in commits: URL, folderID: UUID) throws -> [Snapshot] {
        let manager = FileManager.default
        var snapshots: [Snapshot] = []
        for directory in try manager.contentsOfDirectory(at: commits, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let marker = directory.appendingPathComponent("ready.json")
            if manager.fileExists(atPath: directory.appendingPathComponent(".ready.json.icloud").path) {
                try manager.startDownloadingUbiquitousItem(at: marker)
                throw SyncFailure.unavailable("iCloud is still downloading a snapshot. Keep the folder downloaded and retry.")
            }
            guard manager.fileExists(atPath: marker.path) else { continue }
            let commit = try JSONDecoder().decode(Commit.self, from: availableData(at: marker))
            guard commit.version == 1, commit.state.folderID == folderID,
                  commit.id.uuidString == directory.lastPathComponent,
                  (Array(commit.state.notes.values) + Array(commit.state.notebooks.values)).allSatisfy({
                      $0.counters.values.allSatisfy { $0 >= 0 && $0 < Int.max - 1 }
                  }) else {
                throw JoplinImportError.invalid("The shared folder contains an invalid sync snapshot.")
            }
            try verify(commit, in: directory)
            guard let library = try LibraryStorage(url: directory.appendingPathComponent("library.json")).load() else {
                throw JoplinImportError.invalid("A sync snapshot is still downloading. Keep the folder downloaded and retry.")
            }
            snapshots.append(Snapshot(commit: commit, library: library, folder: directory))
        }
        return snapshots
    }

    private static func merge(_ snapshots: [Snapshot], localState: FolderSyncState, assets: URL) throws -> FolderSyncResult {
        var state = localState
        var summaries: [UUID: SyncConflictSummary] = [:]
        func remember(_ summary: SyncConflictSummary) {
            let previous = summaries[summary.id]
            summaries[summary.id] = SyncConflictSummary(id: summary.id,
                variantIDs: Set((previous?.variantIDs ?? []) + summary.variantIDs).sorted { $0.uuidString < $1.uuidString },
                includesDeletion: summary.includesDeletion || previous?.includesDeletion == true)
        }
        for summary in localState.conflictSummaries ?? [] { remember(summary) }
        for snapshot in snapshots {
            for summary in snapshot.commit.state.conflictSummaries ?? [] { remember(summary) }
        }
        var notebooks: [UUID: Notebook] = [:]
        var notebookVersions: [UUID: [(SyncClock, Notebook?)]] = [:]
        var rememberedNotebooks: [UUID: Notebook] = [:]
        for snapshot in snapshots {
            let present = Dictionary(uniqueKeysWithValues: snapshot.library.notebooks.map { ($0.id, $0) })
            for notebook in snapshot.library.notebooks { rememberedNotebooks[notebook.id] = notebook }
            for (id, clock) in snapshot.commit.state.notebooks {
                notebookVersions[id, default: []].append((clock, present[id]))
                var joined = state.notebooks[id] ?? SyncClock()
                joined.join(clock)
                state.notebooks[id] = joined
            }
        }
        for (id, versions) in notebookVersions {
            let maximal = versions.filter { version in !versions.contains { $0.0.dominates(version.0) } }
            if let winner = maximal.compactMap(\.1).sorted(by: { $0.name < $1.name }).first {
                notebooks[id] = winner
            }
        }
        var candidates: [UUID: [Candidate]] = [:]
        for snapshot in snapshots {
            let notes = Dictionary(uniqueKeysWithValues: snapshot.library.notes.map { ($0.id, $0) })
            for (id, clock) in snapshot.commit.state.notes {
                let note = notes[id]
                candidates[id, default: []].append(Candidate(note: note, clock: clock, snapshot: snapshot,
                    fingerprint: try note.map { try noteFingerprint($0) } ?? "deleted"))
            }
        }
        var notes: [Note] = []
        var conflicts = 0
        for (id, versions) in candidates {
            let maximal = versions.filter { version in !versions.contains { $0.clock.dominates(version.clock) } }
            var unique: [String: Candidate] = [:]
            var clock = SyncClock()
            for candidate in maximal {
                clock.join(candidate.clock)
                unique[candidate.fingerprint] = candidate
            }
            state.notes[id] = clock
            let survivors = unique.values.filter { $0.note != nil }.sorted {
                let lhs = $0.note?.updatedAt ?? .distantPast
                let rhs = $1.note?.updatedAt ?? .distantPast
                return lhs == rhs ? $0.fingerprint < $1.fingerprint : lhs > rhs
            }
            guard let primary = survivors.first, let original = primary.note else { continue }
            var winner = try materialize(original, snapshot: primary.snapshot, assets: assets)
            if unique.count > 1 {
                winner.tags = Note.normalizedTags(winner.tags + ["sync-conflict"])
                conflicts += 1
            }
            notes.append(winner)
            var variantIDs = [id]
            for version in survivors.dropFirst() {
                guard let original = version.note else { continue }
                let conflictID = stableID(id.uuidString + version.fingerprint)
                let restored = try materialize(original, snapshot: version.snapshot, assets: assets)
                variantIDs.append(conflictID)
                let copy = Note(id: conflictID, notebookID: restored.notebookID,
                    title: restored.displayTitle + " (conflict copy)", body: restored.body,
                    tags: restored.tags + ["sync-conflict"], isPinned: restored.isPinned,
                    deletedAt: restored.deletedAt,
                    createdAt: restored.createdAt, updatedAt: restored.updatedAt,
                    importedSourceURL: restored.importedSourceURL, importedRootURL: restored.importedRootURL,
                    format: restored.format, history: restored.history)
                // A conflict copy already published by another device is the same logical copy.
                if !candidates.keys.contains(conflictID) { notes.append(copy) }
                state.notes[conflictID] = clock
            }
            if unique.count > 1 {
                remember(SyncConflictSummary(id: id, variantIDs: variantIDs, includesDeletion: unique["deleted"] != nil))
            }
        }
        for id in Set(notes.map(\.notebookID)) where notebooks[id] == nil {
            notebooks[id] = rememberedNotebooks[id] ?? Notebook(id: id, name: "Recovered notebook")
        }
        let sortedNotebooks = notebooks.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        var library = Library(notebooks: sortedNotebooks, notes: notes.sorted { $0.id.uuidString < $1.id.uuidString })
        state.noteFingerprints = try Dictionary(uniqueKeysWithValues: library.notes.map { ($0.id, try noteFingerprint($0)) })
        state.notebookNames = Dictionary(uniqueKeysWithValues: library.notebooks.map { ($0.id, $0.name) })
        let unresolved = Set(library.notes.filter { $0.tags.contains("sync-conflict") }.map(\.id))
        state.conflictSummaries = summaries.values.compactMap { summary in
            let variants = summary.variantIDs.filter { unresolved.contains($0) }
            return variants.isEmpty ? nil : SyncConflictSummary(id: summary.id, variantIDs: variants,
                                                                includesDeletion: summary.includesDeletion)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        library.folderSync = state
        try library.validate()
        return FolderSyncResult(library: library, conflicts: conflicts)
    }

    private static func materialize(_ note: Note, snapshot: Snapshot, assets: URL) throws -> Note {
        guard let root = note.importedRootURL, let source = note.importedSourceURL else { return note }
        let manager = FileManager.default
        let destination = assets.appendingPathComponent(snapshot.commit.id.uuidString, isDirectory: true)
        if !manager.fileExists(atPath: destination.path) {
            try manager.createDirectory(at: assets, withIntermediateDirectories: true)
            let staging = assets.appendingPathComponent("incoming-" + UUID().uuidString)
            do {
                try manager.copyItem(at: snapshot.folder, to: staging)
                try verify(snapshot.commit, in: staging)
                try manager.moveItem(at: staging, to: destination)
            } catch {
                if manager.fileExists(atPath: staging.path) { try JoplinImport.discardSnapshot(staging, after: error) }
                throw error
            }
        }
        func localURL(_ relative: URL) throws -> URL {
            guard relative.scheme == nil, !relative.relativeString.hasPrefix("/"),
                  let decoded = relative.relativeString.removingPercentEncoding else {
                throw JoplinImportError.invalid("A sync snapshot contains a nonportable attachment path.")
            }
            let url = destination.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(destination.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
                throw JoplinImportError.invalid("A sync attachment points outside its snapshot.")
            }
            return url
        }
        var restored = note
        restored.importedRootURL = try localURL(root)
        restored.importedSourceURL = try localURL(source)
        return restored
    }

    private static func availableData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isSymbolicLink != true else { throw JoplinImportError.invalid("Sync snapshots cannot contain symbolic links.") }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw SyncFailure.unavailable("iCloud is downloading the shared library. Keep the folder downloaded and sync again.")
        }
        return try Data(contentsOf: url)
    }

    private static func verify(_ commit: Commit, in folder: URL) throws {
        guard commit.hashes["library.json"] != nil else { throw LibraryError.invalidLibrary }
        for (path, hash) in commit.hashes {
            let file = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
                  digest(try availableData(at: file)) == hash else {
                throw JoplinImportError.invalid("A sync snapshot is incomplete or damaged. No local notes were replaced. Retry after your cloud provider finishes downloading.")
            }
        }
    }

    private static func fileHashes(in folder: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw LibraryError.invalidLibrary }
        var hashes: [String: String] = [:]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw JoplinImportError.invalid("Sync does not follow symbolic links.") }
            if values.isRegularFile == true {
                let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                hashes[String(path.dropFirst(base.count + 1))] = digest(try Data(contentsOf: file))
            }
        }
        return hashes
    }

    private static func noteFingerprint(_ note: Note) throws -> String {
        var copy = note
        copy.importedSourceURL = nil
        copy.importedRootURL = nil
        return digest(try encoded(copy))
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
