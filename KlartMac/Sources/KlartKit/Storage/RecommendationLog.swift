import Foundation

/// Local learning log: every coaching recommendation the writer judged, kept
/// so coaching quality and the system prompt can be improved over time.
///
/// One JSON file next to `settings.json`, written atomically. Unlike notes
/// there is one file rather than one per record — the volume is human-paced
/// (a click per record), so load-append-rewrite is cheap and keeps the vault
/// story simple: the whole file is sealed exactly like a note.
public actor RecommendationLog {
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// When set, the file is sealed with the vault master key on write and
    /// opened on read. Nil = plaintext mode (vault disabled) or locked.
    private var encryptionKey: SecureBytes?
    /// True while the vault exists but no key is present: writes are refused,
    /// so a stray append can never drop plaintext into a sealed library.
    private var vaultLocked = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Default location: …/Application Support/Klart/recommendations.json
    public static func defaultFileURL() -> URL {
        NoteStore.defaultDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("recommendations.json")
    }

    /// The identity the sealed file is bound to, so a log copied over another
    /// Klart file fails authentication instead of being opened as one.
    private static let aad = Data("klart.recommendations".utf8)

    // MARK: - Key lifecycle (mirrors NoteStore)

    public func setEncryptionKey(_ key: SecureBytes?) {
        encryptionKey = key
        if key != nil { vaultLocked = false }
    }

    /// Convenience for callers and tests holding plain key Data.
    public func setEncryptionKey(_ key: Data?) {
        setEncryptionKey(key.map(SecureBytes.init))
    }

    /// Enters the locked state: no key in memory, all writes refused.
    public func lock() {
        encryptionKey = nil
        vaultLocked = true
    }

    // MARK: - Reading and writing

    public func loadAll() -> [RecommendationRecord] {
        guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty else { return [] }
        guard let data = try? decrypt(raw),
              let records = try? decoder.decode([RecommendationRecord].self, from: data) else { return [] }
        return records
    }

    public func append(_ record: RecommendationRecord) throws {
        guard !vaultLocked else { throw VaultError.locked }
        var records = loadAll()
        records.append(record)
        try write(records)
    }

    public func clear() throws {
        guard !vaultLocked else { throw VaultError.locked }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func count() -> Int { loadAll().count }

    private func write(_ records: [RecommendationRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encrypt(try encoder.encode(records))
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - At-rest encryption

    private func encrypt(_ data: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard let key = encryptionKey else { return data }
        return try key.withData { try VaultCrypto.seal(data, masterKey: $0, aad: Self.aad) }
        #else
        return data
        #endif
    }

    private func decrypt(_ data: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard VaultCrypto.isSealed(data) else { return data }
        guard let key = encryptionKey else { throw VaultError.corruptData }
        return try key.withData { try VaultCrypto.open(data, masterKey: $0, aad: Self.aad) }
        #else
        return data
        #endif
    }

    /// Vault migrations, single-file analogues of NoteStore's *AllOnDisk pair.
    /// Each is a no-op when there is nothing to convert.
    public func encryptOnDisk(masterKey: Data) throws {
        #if canImport(CryptoKit)
        defer { setEncryptionKey(SecureBytes(masterKey)) }
        guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty,
              !VaultCrypto.isSealed(raw) else { return }
        try VaultCrypto.seal(raw, masterKey: masterKey, aad: Self.aad).write(to: fileURL, options: .atomic)
        #else
        throw VaultError.unsupportedPlatform
        #endif
    }

    public func decryptOnDisk(masterKey: Data) throws {
        #if canImport(CryptoKit)
        defer {
            encryptionKey = nil
            vaultLocked = false
        }
        guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty,
              VaultCrypto.isSealed(raw) else { return }
        try VaultCrypto.open(raw, masterKey: masterKey, aad: Self.aad).write(to: fileURL, options: .atomic)
        #else
        throw VaultError.unsupportedPlatform
        #endif
    }

    /// Re-seals the file from `oldKey` to `newKey`. A file already under the
    /// new key — an interrupted rotation resuming — is left alone.
    public func rotateOnDisk(oldKey: Data, newKey: Data) throws {
        #if canImport(CryptoKit)
        defer { setEncryptionKey(SecureBytes(newKey)) }
        guard let raw = try? Data(contentsOf: fileURL), !raw.isEmpty,
              VaultCrypto.isSealed(raw) else { return }
        if (try? VaultCrypto.open(raw, masterKey: newKey, aad: Self.aad)) != nil { return }
        let plaintext = try VaultCrypto.open(raw, masterKey: oldKey, aad: Self.aad)
        try VaultCrypto.seal(plaintext, masterKey: newKey, aad: Self.aad).write(to: fileURL, options: .atomic)
        #else
        throw VaultError.unsupportedPlatform
        #endif
    }
}
