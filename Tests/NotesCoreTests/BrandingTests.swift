import Foundation
import NotesCore
import Testing

struct BrandingTests {
    @Test func deltosDisplayNameKeepsExistingApplicationAndStorageIdentity() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Support/Info.plist"))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        let info = try #require(value as? [String: Any])
        #expect(info["CFBundleName"] as? String == "Deltos")
        #expect(info["CFBundleDisplayName"] as? String == "Deltos")
        #expect(info["CFBundleIdentifier"] as? String == "dev.folio.notes")
        #expect(info["CFBundleExecutable"] as? String == "Deltos")
        #expect(LibraryStorage.applicationDefault.url.deletingLastPathComponent().lastPathComponent == "Folio")
        #expect(TemplateChoice.builtInPackID == "dev.folio.builtin")
        #expect(TemplateChoice.builtIn.allSatisfy { $0.packName == "Deltos" })
    }
}
