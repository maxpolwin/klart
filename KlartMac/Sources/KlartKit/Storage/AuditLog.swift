import Foundation
#if canImport(CryptoKit)
import CryptoKit

/// Tamper-evident local security log: one JSON line per event. Events record
/// WHAT happened and when — never note content, passwords, or key material.
///
/// Each entry carries an HMAC-SHA256 chained over the previous entry, under a
/// random key kept in the Keychain rather than next to the file. The Keychain
/// also holds an anchor (entry count + last MAC) refreshed on every write. So
/// someone who can edit `audit.log` but cannot read Klårt's Keychain items
/// can't forge an entry, regenerate the chain, truncate it, or delete it
/// without `verify()` noticing — and when the app finds its anchor no longer
/// matching the file, it writes a `tamper_detected` entry that stays in the
/// chain for good.
///
/// Logs written before the chain was keyed (plain SHA-256, no `alg` field)
/// stay readable: they verify as a prefix, and the keyed chain continues
/// from their last hash. A plain entry after a keyed one never verifies.
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
        /// The file no longer matched the Keychain anchor when the app
        /// opened it: entries were edited, removed, or the file replaced.
        case tamperDetected = "tamper_detected"
    }

    private struct Entry: Codable {
        let ts: String
        let event: String
        let prev: String
        let hash: String
        /// nil for legacy unkeyed SHA-256 entries.
        let alg: String?
    }

    /// Keychain accounts for the MAC key and the anchor.
    public static let keyAccount = "klart.audit.key"
    public static let anchorAccount = "klart.audit.anchor"

    private static let genesis = "klart-audit-genesis"
    private static let keyedAlg = "hmac-sha256"

    public let fileURL: URL
    private let secrets: SecretStore
    private let key: SymmetricKey
    private var lastHash: String
    private var count: Int
    /// The anchor did not match the file at startup; the next write records it.
    private var pendingTamper: Bool

    public init(fileURL: URL, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets

        let storedKey = secrets.secret(for: Self.keyAccount)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.count == 32 ? $0 : nil }
        let keyData = storedKey ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        if storedKey == nil {
            secrets.setSecret(keyData.base64EncodedString(), for: Self.keyAccount)
        }
        key = SymmetricKey(data: keyData)

        var (entries, malformed) = Self.load(fileURL)
        if storedKey == nil, malformed || entries.contains(where: { $0.alg != nil }) {
            // A keyed log whose key is gone (a restored backup on a new Mac,
            // a reset Keychain) can never verify again. Keep it for reading,
            // start a fresh chain.
            Self.archiveUnverifiable(fileURL)
            secrets.setSecret(nil, for: Self.anchorAccount)
            (entries, malformed) = ([], false)
        }
        lastHash = entries.last?.hash ?? Self.genesis
        count = entries.count
        pendingTamper = malformed
            || !Self.anchorMatches(secrets.secret(for: Self.anchorAccount), entries: entries)
    }

    public func record(_ event: Event) {
        if pendingTamper {
            pendingTamper = false
            append(.tamperDetected)
        }
        append(event)
    }

    /// Verifies the chain and the Keychain anchor. Returns the number of
    /// entries, or nil if any entry is malformed, out of chain, re-hashed,
    /// downgraded, if the file does not match the anchor, or if the log
    /// records earlier tampering.
    public func verify() -> Int? {
        let (entries, malformed) = Self.load(fileURL)
        guard !malformed else { return nil }
        var prev = Self.genesis
        var keyedSeen = false
        for entry in entries {
            guard entry.prev == prev, entry.event != Event.tamperDetected.rawValue else { return nil }
            if entry.alg == Self.keyedAlg {
                keyedSeen = true
                guard entry.hash == Self.mac(key: key, prev: prev, ts: entry.ts, event: entry.event) else {
                    return nil
                }
            } else if entry.alg == nil {
                guard !keyedSeen,
                      entry.hash == Self.legacyHash(prev: prev, ts: entry.ts, event: entry.event)
                else { return nil }
            } else {
                return nil
            }
            prev = entry.hash
        }
        guard Self.anchorMatches(secrets.secret(for: Self.anchorAccount), entries: entries) else {
            return nil
        }
        return entries.count
    }

    // MARK: - Writing

    private func append(_ event: Event) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let hash = Self.mac(key: key, prev: lastHash, ts: ts, event: event.rawValue)
        let entry = Entry(ts: ts, event: event.rawValue, prev: lastHash, hash: hash, alg: Self.keyedAlg)
        guard let line = try? JSONEncoder().encode(entry) else { return }
        let bytes = line + Data("\n".utf8)

        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } else {
                try bytes.write(to: fileURL, options: .atomic)
            }
        } catch {
            return
        }
        lastHash = hash
        count += 1
        secrets.setSecret("\(count) \(hash)", for: Self.anchorAccount)
    }

    // MARK: - Reading

    private static func load(_ url: URL) -> (entries: [Entry], malformed: Bool) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], false) }
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)) else {
                return (entries, true)
            }
            entries.append(entry)
        }
        return (entries, false)
    }

    /// The anchor names the entry count and the last MAC after the most
    /// recent write. One extra entry is tolerated: the app can stop between
    /// appending a line and refreshing the anchor, and that entry is still
    /// chained and keyed, so it proves itself.
    private static func anchorMatches(_ anchor: String?, entries: [Entry]) -> Bool {
        guard let anchor else {
            // Keyed entries are always written together with an anchor.
            return !entries.contains { $0.alg != nil }
        }
        let parts = anchor.split(separator: " ")
        guard parts.count == 2, let anchored = Int(parts[0]), anchored >= 0,
              entries.count == anchored || entries.count == anchored + 1
        else { return false }
        let hashAtAnchor = anchored == 0 ? genesis : entries[anchored - 1].hash
        return hashAtAnchor == String(parts[1])
    }

    private static func archiveUnverifiable(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archived = url.deletingLastPathComponent()
            .appendingPathComponent("audit-unverifiable-\(stamp).log")
        try? FileManager.default.moveItem(at: url, to: archived)
    }

    // MARK: - Hashing

    private static func mac(key: SymmetricKey, prev: String, ts: String, event: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(prev)|\(ts)|\(event)".utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyHash(prev: String, ts: String, event: String) -> String {
        let digest = SHA256.hash(data: Data("\(prev)|\(ts)|\(event)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
