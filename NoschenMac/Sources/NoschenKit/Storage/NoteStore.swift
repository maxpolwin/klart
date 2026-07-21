import Foundation

/// Local-first note persistence: each note is one pretty-printed JSON file in
/// the app's data directory. Writes are atomic so a crash can never corrupt a
/// note. All I/O happens off the main thread (this is an actor).
public actor NoteStore {
    public let directory: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// When set, files are sealed with the vault master key on write and
    /// opened on read. Nil = plaintext mode (vault disabled or locked).
    private var encryptionKey: Data?

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func setEncryptionKey(_ key: Data?) {
        encryptionKey = key
    }

    /// Default notes directory: ~/Library/Application Support/Noschen/Notes
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Noschen/Notes", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// The identity a sealed file is bound to: the note UUID, which is also
    /// the filename — so a ciphertext copied under another note's name
    /// fails authentication instead of impersonating it.
    private static func aad(for id: UUID) -> Data {
        Data(id.uuidString.utf8)
    }

    private static func idFromFilename(_ url: URL) -> UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    /// Loads every note, newest first. Unreadable files are skipped rather
    /// than taking the whole library down.
    public func loadAll() throws -> [Note] {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        var notes: [Note] = []
        for file in files {
            guard let raw = try? Data(contentsOf: file),
                  let data = try? decrypt(raw, noteID: Self.idFromFilename(file)),
                  let note = try? decoder.decode(Note.self, from: data) else { continue }
            notes.append(note)
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ note: Note) throws {
        try ensureDirectory()
        let data = try encrypt(try encoder.encode(note), noteID: note.id)
        try data.write(to: fileURL(for: note.id), options: .atomic)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - At-rest encryption

    private func encrypt(_ data: Data, noteID: UUID) throws -> Data {
        #if canImport(CryptoKit)
        guard let key = encryptionKey else { return data }
        return try VaultCrypto.seal(data, masterKey: key, aad: Self.aad(for: noteID))
        #else
        return data
        #endif
    }

    private func decrypt(_ data: Data, noteID: UUID?) throws -> Data {
        #if canImport(CryptoKit)
        guard VaultCrypto.isSealed(data) else { return data }
        guard let key = encryptionKey else { throw VaultError.corruptData }
        return try VaultCrypto.open(data, masterKey: key, aad: noteID.map(Self.aad(for:)))
        #else
        return data
        #endif
    }

    /// One-time migrations when protection is turned on or off. Both rewrite
    /// every note file atomically with the target representation.
    public func encryptAllOnDisk(masterKey: Data) throws {
        #if canImport(CryptoKit)
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        for file in files {
            let raw = try Data(contentsOf: file)
            guard !VaultCrypto.isSealed(raw) else { continue }
            let aad = Self.idFromFilename(file).map(Self.aad(for:))
            try VaultCrypto.seal(raw, masterKey: masterKey, aad: aad).write(to: file, options: .atomic)
        }
        encryptionKey = masterKey
        #else
        throw VaultError.unsupportedPlatform
        #endif
    }

    public func decryptAllOnDisk(masterKey: Data) throws {
        #if canImport(CryptoKit)
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        for file in files {
            let raw = try Data(contentsOf: file)
            guard VaultCrypto.isSealed(raw) else { continue }
            let aad = Self.idFromFilename(file).map(Self.aad(for:))
            try VaultCrypto.open(raw, masterKey: masterKey, aad: aad).write(to: file, options: .atomic)
        }
        encryptionKey = nil
        #else
        throw VaultError.unsupportedPlatform
        #endif
    }
}

/// App settings persistence, same directory as notes' parent.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        NoteStore.defaultDirectory().deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
