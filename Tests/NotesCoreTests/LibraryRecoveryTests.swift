import Foundation
import NotesCore
import Testing
@testable import Folio

struct LibraryRecoveryTests {
    @Test func dailyCopiesAreValidatedBoundedAndNeverOverwriteTheFirstCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        var library = Library.starter()
        try storage.save(library)
        let firstBytes = try Data(contentsOf: storage.url)
        let firstDay = Date(timeIntervalSince1970: 1_700_006_400)
        try storage.prepareRecoveryCopy(now: firstDay)
        library.notes[0].body = "Changed after first opening"
        try storage.save(library)
        try storage.prepareRecoveryCopy(now: firstDay.addingTimeInterval(60))
        let copies = try FileManager.default.contentsOfDirectory(at: storage.recoveryDirectory, includingPropertiesForKeys: nil)
        #expect(copies.count == 1)
        let firstCopy = try #require(copies.first)
        let preserved = try Data(contentsOf: firstCopy)
        #expect(preserved == firstBytes)
        let unrelated = storage.recoveryDirectory.appendingPathComponent("keep-me.txt")
        try Data("Keep".utf8).write(to: unrelated)
        for day in 1...10 { try storage.prepareRecoveryCopy(now: firstDay.addingTimeInterval(Double(day * 86_400))) }
        let retained = try FileManager.default.contentsOfDirectory(at: storage.recoveryDirectory, includingPropertiesForKeys: nil)
        #expect(retained.count == 8)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        for copy in retained where copy.pathExtension == "json" { try LibraryStorage(url: copy).load()?.validate() }
    }

    @Test func corruptAndFutureLibrariesCannotOverwriteRecoveryCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(.starter())
        try storage.prepareRecoveryCopy()
        let copies = try FileManager.default.contentsOfDirectory(at: storage.recoveryDirectory, includingPropertiesForKeys: nil)
        let copy = try #require(copies.first)
        let before = try Data(contentsOf: copy)
        try Data("broken".utf8).write(to: storage.url)
        #expect(throws: (any Error).self) { try storage.prepareRecoveryCopy() }
        let after = try Data(contentsOf: copy)
        #expect(after == before)
        var future = Library.starter()
        future.version = 999
        try JSONEncoder().encode(future).write(to: storage.url)
        #expect(throws: LibraryError.self) { try storage.prepareRecoveryCopy() }
        let unchanged = try Data(contentsOf: copy)
        #expect(unchanged == before)
    }

    @MainActor @Test func recoveryFailureBlocksEditingRatherThanSkippingProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
        try storage.save(.starter())
        let before = try Data(contentsOf: storage.url)
        try Data("not a folder".utf8).write(to: storage.recoveryDirectory)
        let store = NotesStore(storage: storage)
        #expect(!store.isLoaded)
        #expect(store.errorMessage != nil)
        store.createNote()
        store.save()
        let after = try Data(contentsOf: storage.url)
        #expect(before == after)
    }
}
