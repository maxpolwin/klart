import XCTest
@testable import NoschenKit

final class LLMHTTPTests: XCTestCase {
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
