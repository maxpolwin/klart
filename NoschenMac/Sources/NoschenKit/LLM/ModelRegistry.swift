import Foundation

/// A small on-device model the built-in provider can download and run.
public struct BuiltinModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// On-disk name inside the models directory.
    public let filename: String
    /// Direct download URL. Pin to a HuggingFace revision commit
    /// (`…/resolve/<40-hex-sha>/file.gguf`) whenever possible so the bytes
    /// can never change underneath the checksum.
    public let downloadURL: URL
    /// Exact size when pinned; nil falls back to Content-Length verification.
    public let sizeBytes: Int64?
    /// SHA256 of the file when pinned; nil skips digest verification
    /// (TLS + size check only — pin before shipping a release).
    public let sha256: String?
    /// Approximate download size for UI copy, e.g. "~1.1 GB".
    public let approxDownloadMB: Int
    /// n_ctx to create inference contexts with.
    public let contextLength: Int
    public let description: String

    public init(
        id: String,
        displayName: String,
        filename: String,
        downloadURL: URL,
        sizeBytes: Int64?,
        sha256: String?,
        approxDownloadMB: Int,
        contextLength: Int,
        description: String
    ) {
        self.id = id
        self.displayName = displayName
        self.filename = filename
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.approxDownloadMB = approxDownloadMB
        self.contextLength = contextLength
        self.description = description
    }

    /// Human-readable download size, e.g. "~1.1 GB" / "~469 MB".
    public var sizeLabel: String {
        if approxDownloadMB >= 1000 {
            return String(format: "~%.1f GB", Double(approxDownloadMB) / 1000)
        }
        return "~\(approxDownloadMB) MB"
    }
}

/// The models the built-in provider offers. Hardcoded: two entries don't
/// justify a JSON file, and the compiler checks this one.
///
/// Pinning procedure (same as the legacy Electron registry): on a network
/// that can reach huggingface.co, run
///   curl -s 'https://huggingface.co/api/models/<org>/<repo>?blobs=true'
/// and take `sha` (revision commit for the URL), `siblings[].size`
/// (sizeBytes) and `siblings[].lfs.oid` (sha256) for the file.
public enum ModelRegistry {
    public static let models: [BuiltinModel] = [
        BuiltinModel(
            id: "qwen2.5-1.5b-instruct",
            displayName: "Qwen2.5 1.5B (recommended)",
            filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            // TODO(pin-before-release): replace `main` with the revision
            // commit and fill sizeBytes/sha256 via the procedure above.
            // This environment cannot reach huggingface.co to do it.
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            sizeBytes: nil,
            sha256: nil,
            approxDownloadMB: 1120,
            contextLength: 8192,
            description: "Best quality of the built-in options. Reliably produces the structured feedback format."
        ),
        BuiltinModel(
            id: "qwen2.5-0.5b-instruct",
            displayName: "Qwen2.5 0.5B (small & fast)",
            filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
            sizeBytes: 491_400_032,
            sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
            approxDownloadMB: 469,
            contextLength: 8192,
            description: "Smallest download, fastest responses. Tips can be rougher than the 1.5B model's."
        ),
    ]

    public static let defaultModelID = "qwen2.5-1.5b-instruct"

    public static func model(id: String) -> BuiltinModel? {
        models.first { $0.id == id }
    }

    /// Where downloaded weights live, alongside notes and settings.
    public static func modelsDirectory() -> URL {
        NoteStore.defaultDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static func fileURL(for model: BuiltinModel, in directory: URL) -> URL {
        directory.appendingPathComponent(model.filename)
    }

    /// A model counts as installed when its verified file exists (and, when
    /// the size is pinned, matches exactly — the downloader only moves fully
    /// verified files to the final name, so this is a cheap re-check).
    public static func isInstalled(_ model: BuiltinModel, in directory: URL) -> Bool {
        let path = fileURL(for: model, in: directory).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else {
            return false
        }
        if let expected = model.sizeBytes {
            return size == expected
        }
        return size > 0
    }

    public static func installedModels(in directory: URL) -> [BuiltinModel] {
        models.filter { isInstalled($0, in: directory) }
    }
}
