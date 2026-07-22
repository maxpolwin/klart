import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Long-lived secret storage that ordinary Swift types can't provide:
/// the bytes live in a manually managed, `mlock`ed allocation (never swapped
/// to disk) and are zeroized on destroy/deinit. Swift `Data`/`String` copy
/// freely under ARC and cannot be reliably wiped — so the master key is kept
/// here for its lifetime and only exposed as a short-lived no-copy view for
/// the duration of a crypto call.
///
/// Honest limits: transient copies inside CryptoKit/CommonCrypto and the
/// password string in the UI layer are outside this control. This protects
/// the long-lived copy, which is the one that matters for memory dumps.
public final class SecureBytes: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    public let count: Int
    private let lock = NSLock()
    private var destroyed = false

    public init(_ data: Data) {
        count = data.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        _ = mlock(pointer, max(count, 1))
        data.withUnsafeBytes { source in
            if let base = source.baseAddress, count > 0 {
                pointer.copyMemory(from: base, byteCount: count)
            }
        }
    }

    /// Runs `body` with a no-copy Data view over the locked buffer. The view
    /// must not escape the closure.
    public func withData<R>(_ body: (Data) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        precondition(!destroyed, "SecureBytes used after destroy()")
        let view = Data(bytesNoCopy: pointer, count: count, deallocator: .none)
        return try body(view)
    }

    /// Zeroizes and unlocks the buffer. Safe to call more than once.
    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !destroyed else { return }
        destroyed = true
        let bytes = pointer.bindMemory(to: UInt8.self, capacity: max(count, 1))
        for i in 0..<max(count, 1) {
            // Volatile-style store loop: opaque pointer writes the optimizer
            // cannot prove dead, unlike a memset before free.
            bytes.advanced(by: i).pointee = 0
        }
        _ = munlock(pointer, max(count, 1))
        pointer.deallocate()
    }

    deinit {
        destroy()
    }
}
