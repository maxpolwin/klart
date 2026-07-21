import XCTest
@testable import NoschenKit

final class ModelRegistryTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noschen-registry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRegistryEntriesAreWellFormed() {
        XCTAssertFalse(ModelRegistry.models.isEmpty)
        XCTAssertEqual(
            Set(ModelRegistry.models.map(\.id)).count,
            ModelRegistry.models.count,
            "model ids must be unique"
        )
        for model in ModelRegistry.models {
            XCTAssertEqual(model.downloadURL.scheme, "https", "\(model.id) must download over HTTPS")
            XCTAssertTrue(model.filename.hasSuffix(".gguf"))
            XCTAssertGreaterThan(model.approxDownloadMB, 0)
            XCTAssertGreaterThanOrEqual(model.contextLength, 2048)
        }
    }

    func testPinnedEntriesArePinnedConsistently() {
        for model in ModelRegistry.models where model.sha256 != nil {
            XCTAssertNotNil(model.sizeBytes, "\(model.id): a sha256 pin needs an exact size too")
            XCTAssertEqual(model.sha256?.count, 64)
            XCTAssertNotNil(
                model.sha256?.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                "\(model.id): sha256 must be lowercase hex"
            )
            XCTAssertNotNil(
                model.downloadURL.path.range(of: "/resolve/[0-9a-f]{40}/", options: .regularExpression),
                "\(model.id): a checksum-pinned URL must also pin the revision commit"
            )
        }
    }

    func testDefaultModelResolves() {
        XCTAssertNotNil(ModelRegistry.model(id: ModelRegistry.defaultModelID))
        XCTAssertNil(ModelRegistry.model(id: "no-such-model"))
    }

    func testInstalledDetection() throws {
        let unpinned = ModelRegistry.models.first { $0.sizeBytes == nil }
        let pinned = ModelRegistry.models.first { $0.sizeBytes != nil }

        if let unpinned {
            XCTAssertFalse(ModelRegistry.isInstalled(unpinned, in: tempDir))
            let url = ModelRegistry.fileURL(for: unpinned, in: tempDir)
            try Data("weights".utf8).write(to: url)
            XCTAssertTrue(ModelRegistry.isInstalled(unpinned, in: tempDir))
        }

        if let pinned, let size = pinned.sizeBytes {
            let url = ModelRegistry.fileURL(for: pinned, in: tempDir)
            // Wrong size never counts as installed.
            try Data("short".utf8).write(to: url)
            XCTAssertFalse(ModelRegistry.isInstalled(pinned, in: tempDir))
            // Exact size does (sparse file — no need to write real gigabytes).
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            XCTAssertTrue(ModelRegistry.isInstalled(pinned, in: tempDir))
        }

        XCTAssertEqual(
            Set(ModelRegistry.installedModels(in: tempDir).map(\.id)),
            Set([unpinned?.id, pinned?.id].compactMap { $0 })
        )
    }

    func testSizeLabel() {
        let gigabyte = BuiltinModel(
            id: "a", displayName: "A", filename: "a.gguf",
            downloadURL: URL(string: "https://example.com/a.gguf")!,
            sizeBytes: nil, sha256: nil, approxDownloadMB: 1120,
            contextLength: 8192, description: ""
        )
        XCTAssertEqual(gigabyte.sizeLabel, "~1.1 GB")
        let megabyte = BuiltinModel(
            id: "b", displayName: "B", filename: "b.gguf",
            downloadURL: URL(string: "https://example.com/b.gguf")!,
            sizeBytes: nil, sha256: nil, approxDownloadMB: 469,
            contextLength: 8192, description: ""
        )
        XCTAssertEqual(megabyte.sizeLabel, "~469 MB")
    }
}
