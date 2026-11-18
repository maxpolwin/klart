import XCTest
@testable import KlartKit

final class StorageProfileTests: XCTestCase {
    func testNoProfileKeepsTheRealFolderAndKeychainNames() {
        XCTAssertEqual(StorageProfile.folderName(profile: nil), "Klart")
        XCTAssertEqual(StorageProfile.vaultAccount("klart.vault.masterkey", profile: nil), "klart.vault.masterkey")
        XCTAssertEqual(NoteStore.defaultDirectory(profile: nil).deletingLastPathComponent().lastPathComponent, "Klart")
    }

    func testProfileMovesNotesAndVaultKeysApart() {
        XCTAssertEqual(StorageProfile.folderName(profile: "test"), "Klart-test")
        XCTAssertEqual(StorageProfile.vaultAccount("klart.vault.masterkey.se", profile: "test"),
                       "klart.vault.masterkey.se.test")
        let dir = NoteStore.defaultDirectory(profile: "test")
        XCTAssertEqual(dir.lastPathComponent, "Notes")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "Klart-test")
        // Settings and the recommendation log sit beside Notes, so they follow.
        XCTAssertEqual(RecommendationLog.defaultFileURL().deletingLastPathComponent().lastPathComponent,
                       StorageProfile.folderName())
    }

    func testBadNamesFallBackToTheRealData() {
        let bad = ["", "../x", "a/b", "Test", "-test", "test-", "te st", "a.b", "é",
                   String(repeating: "a", count: 33), "test\n"]
        for name in bad {
            XCTAssertNil(StorageProfile.sanitized(name), "\(name.debugDescription) must be rejected")
            XCTAssertEqual(StorageProfile.folderName(profile: name), "Klart")
            XCTAssertEqual(StorageProfile.vaultAccount("k", profile: name), "k")
        }
        XCTAssertEqual(StorageProfile.sanitized(String(repeating: "a", count: 32)), String(repeating: "a", count: 32))
        XCTAssertEqual(StorageProfile.sanitized("beta-2"), "beta-2")
    }

    func testApiKeyAccountIsNotProfiled() {
        // API keys are shared across profiles by design.
        XCTAssertEqual(ProviderKind.mistral.keychainAccount, "klart.apikey.mistral")
    }
}

final class MistralProviderTests: XCTestCase {
    func testDefaults() {
        XCTAssertEqual(ProviderKind.mistral.displayName, "Mistral")
        XCTAssertEqual(ProviderKind.mistral.defaultBaseURL, "https://api.mistral.ai/v1")
        XCTAssertEqual(ProviderKind.mistral.defaultModel, "mistral-small-latest")
        XCTAssertTrue(ProviderKind.mistral.usesAPIKey)
        XCTAssertFalse(ProviderKind.mistral.allowsInsecureHTTP)
        XCTAssertTrue(ProviderKind.allCases.contains(.mistral))
    }

    func testIsCloudEvenWhenPointedAtLocalhost() {
        XCTAssertFalse(ProviderFactory.isLocal(kind: .mistral, config: .init(baseURL: "https://api.mistral.ai/v1", model: "")))
        XCTAssertFalse(ProviderFactory.isLocal(kind: .mistral, config: .init(baseURL: "http://localhost:9999", model: "")))
    }

    func testClientRequiresHTTPS() throws {
        let secrets = InMemorySecretStore()
        let client = try ProviderFactory.makeClient(
            kind: .mistral, config: .defaults(for: .mistral), secrets: secrets)
        XCTAssertEqual(client.providerName, "Mistral")
        XCTAssertThrowsError(try ProviderFactory.makeClient(
            kind: .mistral, config: .init(baseURL: "http://api.mistral.ai/v1", model: "m"), secrets: secrets))
    }

    func testSettingsRoundTripWithMistralActive() throws {
        var settings = AppSettings()
        settings.activeProvider = .mistral
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.activeProvider, .mistral)
        XCTAssertEqual(back.activeConfig.baseURL, "https://api.mistral.ai/v1")
    }
}
