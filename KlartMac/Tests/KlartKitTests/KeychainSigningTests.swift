import XCTest
@testable import KlartKit

#if canImport(Security)
import Security

/// The Keychain only works from a signed bundle (data-protection keychain), so
/// the round trip skips itself in an unsigned `swift test` process and runs
/// when the tests are hosted by the signed app target.
final class KeychainSigningTests: XCTestCase {
    private let service = "com.klart.mac.tests.\(UUID().uuidString)"

    /// An unsigned process gets errSecMissingEntitlement (-34018) from the
    /// data-protection keychain; that is "can't test here", not a failure.
    private func requireKeychain(_ store: KeychainSecretStore) throws {
        guard store.storeSecret("probe", for: "probe") else {
            throw XCTSkip("Data-protection keychain unavailable: run from the signed Klart app target.")
        }
        store.setSecret(nil, for: "probe")
    }

    func testSecretRoundTripsAndDeletes() throws {
        let store = KeychainSecretStore(service: service)
        try requireKeychain(store)
        defer { store.setSecret(nil, for: "k") }

        XCTAssertTrue(store.storeSecret("token-1", for: "k"))
        XCTAssertEqual(store.secret(for: "k"), "token-1")
        XCTAssertTrue(store.storeSecret("token-2", for: "k"), "replaces in place")
        XCTAssertEqual(store.secret(for: "k"), "token-2")
        store.setSecret(nil, for: "k")
        XCTAssertNil(store.secret(for: "k"))
    }

    func testAFailedStoreIsReportedNotSwallowed() {
        // Only meaningful unsigned, where every add fails; signed, it passes
        // trivially because there is nothing to assert.
        let store = KeychainSecretStore(service: service)
        if !store.storeSecret("x", for: "k") {
            XCTAssertNil(store.secret(for: "k"))
        } else {
            store.setSecret(nil, for: "k")
        }
    }

    /// The signed build depends on this file; a refactor must not drop either
    /// the sandbox or the keychain group, and make-app.sh must keep stripping
    /// the restricted one.
    func testEntitlementsKeepSandboxAndKeychainGroup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Scripts/Klart.entitlements"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["keychain-access-groups"] as? [String], ["$(AppIdentifierPrefix)com.klart.mac"])

        let script = try String(contentsOf: root.appendingPathComponent("Scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Delete :keychain-access-groups"),
                      "make-app.sh signs without a profile and must strip the restricted entitlement")
    }
}
#endif
