import XCTest
@testable import KlartKit

final class LLMHTTPTests: XCTestCase {
    // MARK: Host locality

    func testNumericShorthandAndLookAlikeNamesAreNotLocal() {
        // Resolvers read these as public addresses (134744072 and 0x08080808
        // are 8.8.8.8; 010 can be octal), or they are public names that only
        // start with a private address.
        let hosts = [
            "134744072", "0x08080808", "010.8.8.8", "0x7f.0.0.1", "127.1",
            "192.168.1.1.attacker.example", "10.0.0.1.nip.io",
        ]
        for host in hosts {
            XCTAssertFalse(LLMHTTP.isLocalHost(host), host)
            XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("http://\(host)/v1", allowInsecure: true), host)
        }
    }

    func testSingleLabelAndMDNSHostsStayLocalBehindAllowInsecure() throws {
        // A bare machine name is a common Ollama setup and must keep working.
        XCTAssertNoThrow(try LLMHTTP.normalizeBaseURL("http://mymac:11434", allowInsecure: true))
        XCTAssertNoThrow(try LLMHTTP.normalizeBaseURL("http://studio.local:1234/v1", allowInsecure: true))
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("http://mymac:11434", allowInsecure: false))
        XCTAssertTrue(LLMHTTP.isLocalHost("192.168.1.20"))
        XCTAssertTrue(LLMHTTP.isLocalHost("10.0.0.1."))
        XCTAssertFalse(LLMHTTP.isLocalHost("0.0.0.0"))
    }

    // MARK: normalizeBaseURL

    func testHTTPSAlwaysAccepted() throws {
        let url = try LLMHTTP.normalizeBaseURL("https://openrouter.ai/api/v1/", allowInsecure: false)
        XCTAssertEqual(url.absoluteString, "https://openrouter.ai/api/v1")
    }

    func testLocalHTTPAcceptedWhenProviderAllowsIt() throws {
        XCTAssertEqual(
            try LLMHTTP.normalizeBaseURL("http://localhost:11434", allowInsecure: true).host,
            "localhost"
        )
        XCTAssertEqual(
            try LLMHTTP.normalizeBaseURL("http://192.168.1.20:1234/v1", allowInsecure: true).host,
            "192.168.1.20"
        )
    }

    func testRemoteHTTPRejectedEvenWhenProviderAllowsInsecure() {
        XCTAssertThrowsError(
            try LLMHTTP.normalizeBaseURL("http://api.example.com/v1", allowInsecure: true)
        ) { error in
            guard case LLMError.insecureURL = error else {
                return XCTFail("expected insecureURL, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try LLMHTTP.normalizeBaseURL("http://8.8.8.8/v1", allowInsecure: true)
        )
    }

    func testHTTPRejectedWhenProviderForbidsInsecure() {
        XCTAssertThrowsError(
            try LLMHTTP.normalizeBaseURL("http://localhost:11434", allowInsecure: false)
        )
    }

    func testGarbageAndNonHTTPSchemesRejected() {
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("not a url", allowInsecure: true))
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("ftp://localhost", allowInsecure: true))
        XCTAssertThrowsError(try LLMHTTP.normalizeBaseURL("file:///etc/hosts", allowInsecure: true))
    }

    // MARK: isLocalHost

    func testLoopbackAndPrivateRangesAreLocal() {
        for host in [
            "localhost", "127.0.0.1", "127.5.0.9", "::1",
            "10.0.0.5", "192.168.0.1", "172.16.0.1", "172.31.255.254",
            "169.254.1.1", "100.64.0.1", "100.127.255.254",
            "fe80::1", "fd12:3456::1", "fc00::1",
            "mymac", "studio.local", "server.lan", "box.internal", "nas.home.arpa",
            "MyMac.LOCAL",
        ] {
            XCTAssertTrue(LLMHTTP.isLocalHost(host), "\(host) should be local")
        }
    }

    func testPublicHostsAreNotLocal() {
        for host in [
            "example.com", "api.openai.com", "8.8.8.8", "1.1.1.1",
            "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1",
            "11.0.0.1", "193.168.0.1", "2606:4700::1111",
            "local.example.com", "999.1.1.1",
        ] {
            XCTAssertFalse(LLMHTTP.isLocalHost(host), "\(host) should NOT be local")
        }
    }
}
