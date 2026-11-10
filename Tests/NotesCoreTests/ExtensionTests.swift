import Foundation
import NotesCore
import Testing

struct ExtensionTests {
    @Test func loadsACommunityTemplatePackAndExpandsOnlyDocumentedTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pack = root.appendingPathComponent("community")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        {"id":"org.example.templates","name":"Community","apiVersion":1,
         "templates":[{"id":"daily","name":"Daily","title":"{{date}}",
         "body":"# Today\\n{{time}}\\n{{not-code}}","tags":["journal"]}]}
        """
        try source.write(to: pack.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        let loaded = try NoteExtensions.load(from: root)
        #expect(loaded.count == 1)
        let template = try #require(loaded.first?.templates.first)
        #expect(!template.render(template.title).contains("{{date}}"))
        #expect(template.render(template.body).contains("{{not-code}}"))
    }

    @Test func unsupportedAPIVersionIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pack = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        {"id":"org.example.bad","name":"Bad","apiVersion":99,"templates":[]}
        """
        try source.write(to: pack.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try NoteExtensions.load(from: root) }
    }
}
