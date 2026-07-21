import Foundation

/// Reassembles a byte stream into valid UTF-8 text. Token pieces from a GGUF
/// vocabulary can split multi-byte characters (emoji, umlauts, CJK), so
/// decoding each piece on its own would inject U+FFFD replacements into the
/// stream; this buffers trailing incomplete sequences until their
/// continuation bytes arrive.
public struct UTF8Accumulator {
    private var pending: [UInt8] = []

    public init() {}

    /// Appends bytes and returns whatever decodes to complete characters.
    public mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let completeCount = pending.count - Self.incompleteSuffixLength(of: pending)
        guard completeCount > 0 else { return "" }
        let complete = pending[0..<completeCount]
        pending.removeFirst(completeCount)
        return String(decoding: complete, as: UTF8.self)
    }

    /// Drains any leftover bytes (lossy for a truncated final sequence).
    public mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }

    /// Number of trailing bytes that form the start of an unfinished UTF-8
    /// sequence (0 when the buffer ends on a character boundary).
    private static func incompleteSuffixLength(of bytes: [UInt8]) -> Int {
        // A UTF-8 sequence is at most 4 bytes; only the last 3 positions can
        // hold an unfinished lead byte.
        let window = min(3, bytes.count)
        for back in 1...max(1, window) where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte, keep looking
            let expected: Int
            if byte & 0b1000_0000 == 0 { expected = 1 }
            else if byte & 0b1110_0000 == 0b1100_0000 { expected = 2 }
            else if byte & 0b1111_0000 == 0b1110_0000 { expected = 3 }
            else if byte & 0b1111_1000 == 0b1111_0000 { expected = 4 }
            else { return 0 }  // invalid lead byte: let String(decoding:) handle it
            return expected > back ? back : 0
        }
        return 0
    }
}
