import Foundation
#if canImport(CryptoKit)
import CryptoKit

/// Tamper-evident local security log: one JSON line per event, each carrying
/// a SHA-256 hash chained over the previous entry. Editing or deleting any
/// line breaks verification of everything after it. Events record WHAT
/// happened and when — never note content, passwords, or key material.
public actor AuditLog {
    public enum Event: String, Sendable {
        case vaultEnabled = "vault_enabled"
        case vaultDisabled = "vault_disabled"
        case unlockSuccess = "unlock_success"
        case unlockFailure = "unlock_failure"
        case biometricUnlockSuccess = "biometric_unlock_success"
        case biometricUnlockFailure = "biometric_unlock_failure"
        case locked = "locked"
        case keyRotated = "key_rotated"
        case unlockThrottled = "unlock_throttled"
    }

    private struct Entry: Codable {
        let ts: String
        let event: String
        let prev: String
        let hash: String
    }

    public let fileURL: URL
    private var lastHash: String

    public init(fileURL: URL) {
        self.fileURL = fileURL
        // Resume the chain from the last line, or start at the genesis value.
        if let text = try? String(contentsOf: fileURL, encoding: .utf8),
           let lastLine = text.split(separator: "\n").last,
           let entry = try? JSONDecoder().decode(Entry.self, from: Data(lastLine.utf8)) {
            lastHash = entry.hash
        } else {
            lastHash = Self.genesis
        }
    }

    private static let genesis = "klart-audit-genesis"

    private static func hash(prev: String, ts: String, event: String) -> String {
        let digest = SHA256.hash(data: Data("\(prev)|\(ts)|\(event)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func record(_ event: Event) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = Entry(
            ts: ts,
            event: event.rawValue,
            prev: lastHash,
            hash: Self.hash(prev: lastHash, ts: ts, event: event.rawValue)
        )
        guard let line = try? JSONEncoder().encode(entry) else { return }
        lastHash = entry.hash

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        } else {
            try? (line + Data("\n".utf8)).write(to: fileURL, options: .atomic)
        }
    }

    /// Verifies the whole chain. Returns the number of valid entries, or nil
    /// if any entry is malformed, out of chain, or re-hashed.
    public static func verifyChain(at url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var prev = genesis
        var count = 0
        for line in text.split(separator: "\n") {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)),
                  entry.prev == prev,
                  entry.hash == hash(prev: prev, ts: entry.ts, event: entry.event)
            else { return nil }
            prev = entry.hash
            count += 1
        }
        return count
    }
}
#endif
