import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a built-in model is in its download lifecycle.
public enum ModelDownloadState: Equatable, Sendable {
    case notInstalled
    case downloading(bytes: Int64, total: Int64?)
    case verifying
    case installed
    case failed(String)
}

/// Downloads built-in model weights: resumable, SHA256-verified, atomic.
///
/// Bytes stream into `<filename>.partial`; only a fully verified file is
/// moved to the final name, so the final filename never holds a corrupt or
/// truncated download. Cancellation and network failures keep the partial
/// for a later resume (HTTP Range).
public actor ModelDownloadManager {
    public let directory: URL
    private let session: URLSession
    private var activeDownloads: [String: Task<Void, Never>] = [:]
    private var lastKnownStates: [String: ModelDownloadState] = [:]

    /// - Parameter sessionConfiguration: injectable for tests (URLProtocol
    ///   stubs). The request timeout acts as the stall detector: it resets on
    ///   every packet, so it only fires when the stream goes quiet.
    public init(
        directory: URL = ModelRegistry.modelsDirectory(),
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.directory = directory
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    public func state(for model: BuiltinModel) -> ModelDownloadState {
        if activeDownloads[model.id] != nil {
            return lastKnownStates[model.id] ?? .downloading(bytes: 0, total: model.sizeBytes)
        }
        if ModelRegistry.isInstalled(model, in: directory) {
            return .installed
        }
        if let last = lastKnownStates[model.id], case .failed = last {
            return last
        }
        return .notInstalled
    }

    /// Starts (or resumes) the download. The stream yields state changes and
    /// finishes after `.installed` or `.failed`. If a download for this model
    /// is already running, the stream just reports the current state and
    /// finishes — one download per model at a time.
    public func download(_ model: BuiltinModel) -> AsyncStream<ModelDownloadState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelDownloadState.self)
        guard activeDownloads[model.id] == nil else {
            continuation.yield(state(for: model))
            continuation.finish()
            return stream
        }
        guard !ModelRegistry.isInstalled(model, in: directory) else {
            continuation.yield(.installed)
            continuation.finish()
            return stream
        }
        lastKnownStates[model.id] = .downloading(bytes: 0, total: model.sizeBytes)
        let task = Task {
            await self.performDownload(model) { state in
                continuation.yield(state)
            }
            continuation.finish()
        }
        activeDownloads[model.id] = task
        return stream
    }

    /// Stops an in-flight download, keeping the partial file for resume.
    public func cancel(_ model: BuiltinModel) {
        activeDownloads[model.id]?.cancel()
    }

    /// Removes the installed file (and any partial). Callers should unload
    /// the runtime first if this model is resident.
    public func delete(_ model: BuiltinModel) throws {
        cancel(model)
        let fileManager = FileManager.default
        for url in [finalURL(for: model), partialURL(for: model)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        lastKnownStates[model.id] = nil
    }

    // MARK: - Internals

    private func finalURL(for model: BuiltinModel) -> URL {
        ModelRegistry.fileURL(for: model, in: directory)
    }

    private func partialURL(for model: BuiltinModel) -> URL {
        directory.appendingPathComponent(model.filename + ".partial")
    }

    private func setState(_ state: ModelDownloadState, for model: BuiltinModel, yield: (ModelDownloadState) -> Void) {
        lastKnownStates[model.id] = state
        yield(state)
    }

    private func performDownload(_ model: BuiltinModel, yield: (ModelDownloadState) -> Void) async {
        defer { activeDownloads[model.id] = nil }
        do {
            try await runDownload(model, yield: yield)
        } catch is CancellationError {
            // Partial stays on disk; next download call resumes.
            lastKnownStates[model.id] = nil
            yield(.notInstalled)
        } catch let error as URLError where error.code == .cancelled {
            lastKnownStates[model.id] = nil
            yield(.notInstalled)
        } catch {
            let message = (error as? DownloadFailure)?.message ?? error.localizedDescription
            setState(.failed(message), for: model, yield: yield)
        }
    }

    private struct DownloadFailure: Error {
        let message: String
    }

    private func runDownload(_ model: BuiltinModel, yield: (ModelDownloadState) -> Void) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let partial = partialURL(for: model)
        var hasher = SHA256()
        var received: Int64 = 0

        // Resume support: hash what's already on disk so the final digest
        // covers the whole file, then ask the server for the remainder.
        if fileManager.fileExists(atPath: partial.path) {
            received = try hashExistingPartial(at: partial, into: &hasher)
        } else {
            fileManager.createFile(atPath: partial.path, contents: nil)
        }

        try checkDiskSpace(for: model, alreadyDownloaded: received)

        var request = URLRequest(url: model.downloadURL)
        // identity: a compressed transfer would break Range math and hashing.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 {
            request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadFailure(message: "Unexpected response from the download server.")
        }

        switch http.statusCode {
        case 206:
            break  // server honors the resume
        case 200:
            // Server ignored the Range header: start over from zero.
            if received > 0 {
                try fileManager.removeItem(at: partial)
                fileManager.createFile(atPath: partial.path, contents: nil)
                hasher = SHA256()
                received = 0
            }
        case 416:
            // Requested range starts at/after the end: the partial may
            // already be complete — fall through to verification.
            try await finishAndVerify(model, partial: partial, hasher: hasher, received: received, yield: yield)
            return
        default:
            throw DownloadFailure(message: "Download failed: HTTP \(http.statusCode) from the model server.")
        }

        let expectedTotal = expectedTotalBytes(model: model, response: http, alreadyReceived: received)
        setState(.downloading(bytes: received, total: expectedTotal), for: model, yield: yield)

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()

        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 20)
        var lastReportedBytes = received

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try Task.checkCancellation()
                let chunk = Data(buffer)
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                received += Int64(chunk.count)
                buffer.removeAll(keepingCapacity: true)
                if received - lastReportedBytes >= 8 << 20 {
                    lastReportedBytes = received
                    setState(.downloading(bytes: received, total: expectedTotal), for: model, yield: yield)
                }
            }
        }
        if !buffer.isEmpty {
            let chunk = Data(buffer)
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            received += Int64(chunk.count)
        }
        try handle.close()

        try await finishAndVerify(model, partial: partial, hasher: hasher, received: received, yield: yield)
    }

    private func finishAndVerify(
        _ model: BuiltinModel,
        partial: URL,
        hasher: SHA256,
        received: Int64,
        yield: (ModelDownloadState) -> Void
    ) async throws {
        setState(.verifying, for: model, yield: yield)

        if let expected = model.sizeBytes, received != expected {
            try? FileManager.default.removeItem(at: partial)
            throw DownloadFailure(message: "Download incomplete (\(received) of \(expected) bytes). Please try again.")
        }
        if let expectedDigest = model.sha256 {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedDigest.lowercased() else {
                try? FileManager.default.removeItem(at: partial)
                throw DownloadFailure(message: "Checksum verification failed — the download was corrupted or tampered with. It has been removed; please try again.")
            }
        }
        guard received > 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw DownloadFailure(message: "The server returned an empty file.")
        }

        let destination = finalURL(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        setState(.installed, for: model, yield: yield)
    }

    private func hashExistingPartial(at url: URL, into hasher: inout SHA256) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return total
    }

    private func expectedTotalBytes(model: BuiltinModel, response: HTTPURLResponse, alreadyReceived: Int64) -> Int64? {
        if let pinned = model.sizeBytes { return pinned }
        let contentLength = response.expectedContentLength
        guard contentLength > 0 else { return nil }
        // For a 206 the Content-Length covers only the remainder.
        return response.statusCode == 206 ? alreadyReceived + contentLength : contentLength
    }

    private func checkDiskSpace(for model: BuiltinModel, alreadyDownloaded: Int64) throws {
        let needed = (model.sizeBytes ?? Int64(model.approxDownloadMB) * 1_000_000) - alreadyDownloaded
        guard needed > 0 else { return }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage,
           available < needed + needed / 20 {
            throw DownloadFailure(message: "Not enough free disk space: the model needs about \(model.sizeLabel).")
        }
    }
}
