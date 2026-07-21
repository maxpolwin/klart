import XCTest
import CryptoKit
@testable import NoschenKit

/// Serves canned responses to the download manager's URLSession and records
/// every request it sees, so resume headers can be asserted.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?
    static var recorded: [URLRequest] = []

    static func reset() {
        handler = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Length": String(body.count)]) { a, _ in a }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ModelDownloadManagerTests: XCTestCase {
    var tempDir: URL!
    var manager: ModelDownloadManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-downloads-\(UUID().uuidString)", isDirectory: true)
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        manager = ModelDownloadManager(directory: tempDir, sessionConfiguration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeModel(payload: Data, pinned: Bool) -> BuiltinModel {
        BuiltinModel(
            id: "test-model",
            displayName: "Test Model",
            filename: "test-model.gguf",
            downloadURL: URL(string: "https://example.com/test-model.gguf")!,
            sizeBytes: pinned ? Int64(payload.count) : nil,
            sha256: pinned ? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() : nil,
            approxDownloadMB: 1,
            contextLength: 8192,
            description: "test"
        )
    }

    private func collect(_ stream: AsyncStream<ModelDownloadState>) async -> [ModelDownloadState] {
        var states: [ModelDownloadState] = []
        for await state in stream {
            states.append(state)
        }
        return states
    }

    func testHappyPathDownloadsVerifiesAndInstalls() async throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let model = makeModel(payload: payload, pinned: true)
        StubURLProtocol.handler = { _ in (200, [:], payload) }

        let states = await collect(await manager.download(model))

        XCTAssertEqual(states.last, .installed)
        XCTAssertTrue(states.contains(.verifying))
        let installed = ModelRegistry.fileURL(for: model, in: tempDir)
        XCTAssertEqual(try Data(contentsOf: installed), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path + ".partial"))
        let state = await manager.state(for: model)
        XCTAssertEqual(state, .installed)
    }

    func testChecksumMismatchFailsAndRemovesFile() async throws {
        let payload = Data("real payload".utf8)
        var model = makeModel(payload: payload, pinned: true)
        model = BuiltinModel(
            id: model.id, displayName: model.displayName, filename: model.filename,
            downloadURL: model.downloadURL, sizeBytes: model.sizeBytes,
            sha256: String(repeating: "0", count: 64),
            approxDownloadMB: model.approxDownloadMB,
            contextLength: model.contextLength, description: model.description
        )
        StubURLProtocol.handler = { _ in (200, [:], payload) }

        let states = await collect(await manager.download(model))

        guard case .failed(let message)? = states.last else {
            return XCTFail("expected failure, got \(String(describing: states.last))")
        }
        XCTAssertTrue(message.lowercased().contains("checksum"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelRegistry.fileURL(for: model, in: tempDir).path))
    }

    func testSizeMismatchFails() async throws {
        let payload = Data("only half of the promised bytes".utf8)
        var model = makeModel(payload: payload, pinned: true)
        model = BuiltinModel(
            id: model.id, displayName: model.displayName, filename: model.filename,
            downloadURL: model.downloadURL,
            sizeBytes: Int64(payload.count) * 2,
            sha256: model.sha256,
            approxDownloadMB: model.approxDownloadMB,
            contextLength: model.contextLength, description: model.description
        )
        StubURLProtocol.handler = { _ in (200, [:], payload) }

        let states = await collect(await manager.download(model))

        guard case .failed? = states.last else {
            return XCTFail("expected failure, got \(String(describing: states.last))")
        }
    }

    func testResumeSendsRangeHeaderAndDigestCoversWholeFile() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 249) })
        let model = makeModel(payload: payload, pinned: true)

        // Simulate an interrupted earlier download: half the file on disk.
        let splitAt = payload.count / 2
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try payload[0..<splitAt].write(to: tempDir.appendingPathComponent(model.filename + ".partial"))

        StubURLProtocol.handler = { request in
            guard let range = request.value(forHTTPHeaderField: "Range") else {
                return (500, [:], Data())
            }
            XCTAssertEqual(range, "bytes=\(splitAt)-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            return (206, ["Content-Range": "bytes \(splitAt)-\(payload.count - 1)/\(payload.count)"], payload[splitAt...])
        }

        let states = await collect(await manager.download(model))

        XCTAssertEqual(states.last, .installed)
        XCTAssertEqual(try Data(contentsOf: ModelRegistry.fileURL(for: model, in: tempDir)), payload)
    }

    func testServerIgnoringRangeRestartsFromZero() async throws {
        let payload = Data((0..<20_000).map { UInt8($0 % 245) })
        let model = makeModel(payload: payload, pinned: true)

        // Poison the partial: if the manager appended instead of restarting,
        // both size and digest would fail.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("stale garbage".utf8).write(to: tempDir.appendingPathComponent(model.filename + ".partial"))

        StubURLProtocol.handler = { _ in (200, [:], payload) }

        let states = await collect(await manager.download(model))

        XCTAssertEqual(states.last, .installed)
        XCTAssertEqual(try Data(contentsOf: ModelRegistry.fileURL(for: model, in: tempDir)), payload)
    }

    func testUnpinnedModelVerifiesAgainstReceivedBytes() async throws {
        let payload = Data("unpinned model payload".utf8)
        let model = makeModel(payload: payload, pinned: false)
        StubURLProtocol.handler = { _ in (200, [:], payload) }

        let states = await collect(await manager.download(model))

        XCTAssertEqual(states.last, .installed)
        XCTAssertEqual(try Data(contentsOf: ModelRegistry.fileURL(for: model, in: tempDir)), payload)
    }

    func testAlreadyInstalledShortCircuits() async throws {
        let payload = Data("payload".utf8)
        let model = makeModel(payload: payload, pinned: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try payload.write(to: ModelRegistry.fileURL(for: model, in: tempDir))

        let states = await collect(await manager.download(model))

        XCTAssertEqual(states, [.installed])
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty, "no network traffic for an installed model")
    }

    func testDeleteRemovesFileAndPartial() async throws {
        let payload = Data("payload".utf8)
        let model = makeModel(payload: payload, pinned: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try payload.write(to: ModelRegistry.fileURL(for: model, in: tempDir))
        try Data("partial".utf8).write(to: tempDir.appendingPathComponent(model.filename + ".partial"))

        try await manager.delete(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelRegistry.fileURL(for: model, in: tempDir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(model.filename + ".partial").path))
        let state = await manager.state(for: model)
        XCTAssertEqual(state, .notInstalled)
    }
}
