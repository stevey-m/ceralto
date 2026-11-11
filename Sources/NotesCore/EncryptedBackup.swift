import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum EncryptedBackup {
    public static let fileExtension = "deltosbackup"
    public static let maximumPlaintextBytes = 256 * 1_024 * 1_024
    private static let magic = Data("DELTOSB1".utf8)
    private static let rounds: UInt32 = 600_000
    private static let headerSize = 28

    private struct Payload: Codable {
        let version: Int
        let files: [String: Data]
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, limit - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else { throw failure("The backup exceeds the supported size.") }
            result.append(chunk)
        }
        return result
    }

    public static func export(_ library: Library, to destination: URL, password: String) throws {
        guard password.count >= 12, password.utf8.count <= 1_024 else {
            throw failure("Use a password of at least 12 characters and no more than 1,024 UTF-8 bytes.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw failure("Existing files are never overwritten. Choose a new encrypted backup filename.")
        }
        let (portable, roots) = try LibraryBackup.portableSnapshot(library, avoiding: destination)
        let encoder = JSONEncoder()
        var files = ["library.json": try encoder.encode(portable)]
        var total = files["library.json"]?.count ?? 0
        guard total <= maximumPlaintextBytes else { throw failure("The library manifest exceeds 256 MiB.") }
        for (root, prefix) in roots {
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw failure("Could not read the attachment folder.") }
            for case let file as URL in enumerator {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true else { throw failure("Encrypted backups cannot contain symbolic links.") }
                if info.isDirectory == true { continue }
                guard info.isRegularFile == true, let size = info.fileSize, size <= maximumPlaintextBytes - total else {
                    throw failure("The complete backup exceeds the 256 MiB encrypted-backup limit or contains a special file.")
                }
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let path = prefix + "/" + relative
                try validatePath(path)
                let bytes = try readBounded(file, limit: maximumPlaintextBytes - total)
                guard bytes.count <= maximumPlaintextBytes - total, files.count < 50_000 else {
                    throw failure("The complete backup exceeds the size or 50,000-file limit.")
                }
                total += bytes.count
                files[path] = bytes
            }
            if let enumerationError { throw enumerationError }
        }
        let plaintext = try encoder.encode(Payload(version: 1, files: files))
        guard plaintext.count <= maximumPlaintextBytes else {
            throw failure("The encoded complete backup exceeds 256 MiB. Use a smaller library or an unencrypted complete backup.")
        }
        let salt = try randomBytes(count: 16)
        var header = magic
        header.append(salt)
        var cost = rounds.bigEndian
        withUnsafeBytes(of: &cost) { header.append(contentsOf: $0) }
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw failure("Could not seal the backup.") }
        let output = header + combined
        // Verify authentication before publishing; no plaintext staging files are created on export.
        let verification = try AES.GCM.open(sealed, using: key, authenticating: header)
        guard verification == plaintext else { throw failure("Encrypted backup verification failed.") }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".deltos-encrypted-" + UUID().uuidString)
        do {
            try output.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try JoplinImport.discardSnapshot(temporary, after: error)
            }
            throw error
        }
    }

    public static func imported(from archive: URL, password: String, importsDirectory: URL) throws -> JoplinImportResult {
        guard !password.isEmpty, password.utf8.count <= 1_024 else { throw failure("Enter the backup password.") }
        let info = try archive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize,
              size >= headerSize + 28, size <= maximumPlaintextBytes + headerSize + 28 else {
            throw failure("This encrypted backup is truncated or exceeds the supported size.")
        }
        let data = try readBounded(archive, limit: maximumPlaintextBytes + headerSize + 28)
        guard data.count == size, data.prefix(8) == magic,
              data[24..<28].reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == rounds else {
            throw failure("This is not a supported Ceralto encrypted backup.")
        }
        let header = Data(data.prefix(headerSize))
        let salt = Data(data[8..<24])
        let key = try deriveKey(password: password, salt: salt)
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: data.dropFirst(headerSize))
            plaintext = try AES.GCM.open(sealed, using: key, authenticating: header)
        } catch {
            throw failure("The password is incorrect or the encrypted backup has been damaged. Nothing was imported.")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
        guard payload.version == 1, payload.files.count <= 50_000,
              let manifest = payload.files["library.json"] else { throw failure("Invalid encrypted backup contents.") }
        let library = try JSONDecoder().decode(Library.self, from: manifest)
        try library.validate()
        var paths = Set<String>()
        for path in payload.files.keys {
            try validatePath(path)
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw failure("The backup contains duplicate file paths.") }
        }
        let staging = importsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        do {
            for (path, bytes) in payload.files {
                let target = staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try bytes.write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            return try LibraryBackup.importedSnapshot(at: staging)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) { try JoplinImport.discardSnapshot(staging, after: error) }
            throw error
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                passwordBytes.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw failure("Password key derivation failed.") }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!) }
        guard status == errSecSuccess else { throw failure("Could not obtain secure random bytes.") }
        return bytes
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == "library.json" || path.hasPrefix("resources/"),
              !path.contains("\\"), !path.contains("\0"), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("The encrypted backup contains an unsafe path.")
        }
    }

    private static func failure(_ text: String) -> JoplinImportError { .invalid(text) }
}
