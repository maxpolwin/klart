import Foundation

/// Lets a debug build keep its notes, settings and vault keys apart from the
/// real ones. Set `KLART_PROFILE=test` in the Xcode scheme and the build uses
/// `Klart-test/` next to `Klart/`, and its own vault keychain names. API keys
/// stay shared on purpose (one Keychain service, one set of provider keys).
///
/// A name, never a path: the sandbox only lets the app write inside its
/// container, and a name cannot be turned into a traversal. Compiled out of
/// release builds, so the shipped app has no environment switch at all.
public enum StorageProfile {
    /// The active profile, or nil for the real data. Read once at launch.
    public static let current: String? = {
        #if DEBUG
        return sanitized(ProcessInfo.processInfo.environment["KLART_PROFILE"])
        #else
        return nil
        #endif
    }()

    /// Allowlist: 1–32 characters of `a-z 0-9 -`, not starting or ending with
    /// `-`. Anything else is ignored, so a bad value falls back to the real
    /// data rather than to an odd folder.
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw, (1...32).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }),
              raw.first != "-", raw.last != "-"
        else { return nil }
        return raw
    }

    /// `Klart` for the real data, `Klart-<profile>` for a profile.
    public static func folderName(profile: String? = current) -> String {
        guard let profile = sanitized(profile) else { return "Klart" }
        return "Klart-\(profile)"
    }

    /// A vault keychain account, suffixed per profile so a test build can never
    /// read, overwrite or delete the real vault's keys.
    public static func vaultAccount(_ base: String, profile: String? = current) -> String {
        guard let profile = sanitized(profile) else { return base }
        return "\(base).\(profile)"
    }
}
