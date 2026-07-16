import Foundation

/// Local-first note persistence: each note is one pretty-printed JSON file in
/// the app's data directory. Writes are atomic so a crash can never corrupt a
/// note. All I/O happens off the main thread (this is an actor).
public actor NoteStore {
    public let directory: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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

    /// Loads every note, newest first. Unreadable files are skipped rather
    /// than taking the whole library down.
    public func loadAll() throws -> [Note] {
        try ensureDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        var notes: [Note] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let note = try? decoder.decode(Note.self, from: data) else { continue }
            notes.append(note)
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ note: Note) throws {
        try ensureDirectory()
        let data = try encoder.encode(note)
        try data.write(to: fileURL(for: note.id), options: .atomic)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
