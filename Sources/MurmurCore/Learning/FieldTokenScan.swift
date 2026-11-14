import Foundation

/// One pass over a field's UTF-8 bytes that does what `CorrectionAlignment.tokens` followed by
/// `CorrectionAlignment.key` and interning do, without building a `String` per token for ASCII text.
///
/// Why: on a 20,000-token field the `Character`-based split and per-token `lowercased().filter`
/// cost about 40 ms in a release build, far more than locating the dictation (about 1 ms). An ASCII
/// token is keyed straight from its bytes; a token with any non-ASCII byte (accents, curly quotes,
/// emoji, no-break spaces) goes through the original `Character` code, so the result is identical.
/// `FieldTokenScanTests` compares the two on mixed text.
struct FieldTokenScan {
    /// Interned id of each token's comparison key: the dictation's ids, -1 for any other key.
    let ids: [Int32]
    /// UTF-8 byte range of each token in `bytes`.
    let ranges: [Range<Int>]
    let bytes: [UInt8]

    var count: Int { ids.count }

    /// `vocabulary` maps the dictation's non-empty comparison keys to ids.
    init(_ text: String, vocabulary: [String: Int32]) {
        let bytes = Array(text.utf8)
        var ids: [Int32] = []
        var ranges: [Range<Int>] = []
        ids.reserveCapacity(bytes.count / 5)
        ranges.reserveCapacity(bytes.count / 5)
        var key: [UInt8] = []
        key.reserveCapacity(32)
        var index = 0
        while index < bytes.count {
            if Self.isASCIISpace(bytes[index]) { index += 1; continue }
            let start = index
            var isASCII = true
            key.removeAll(keepingCapacity: true)
            while index < bytes.count, !Self.isASCIISpace(bytes[index]) {
                let byte = bytes[index]
                if byte >= 0x80 {
                    isASCII = false
                } else if let lowered = Self.keyByte(byte) {
                    key.append(lowered)
                }
                index += 1
            }
            if isASCII {
                ranges.append(start..<index)
                ids.append(key.isEmpty ? -1 : vocabulary[String(decoding: key, as: UTF8.self)] ?? -1)
            } else {
                // Rare path: let `Character` decide where tokens end and what the key is.
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                var offset = start
                for piece in Self.characterTokens(token) {
                    let skipped = Self.leadingWhitespaceBytes(in: bytes, from: offset)
                    let pieceStart = offset + skipped
                    let pieceEnd = pieceStart + piece.utf8.count
                    ranges.append(pieceStart..<pieceEnd)
                    ids.append(vocabulary[CorrectionAlignment.key(piece)] ?? -1)
                    offset = pieceEnd
                }
            }
        }
        self.ids = ids
        self.ranges = ranges
        self.bytes = bytes
    }

    /// The token strings for `range` of token indices.
    func tokens(_ range: ClosedRange<Int>) -> [String] {
        range.map { String(decoding: bytes[ranges[$0]], as: UTF8.self) }
    }

    /// True when the gap after token `index` holds a line break and then more text, i.e. the text
    /// continues on a new line ("...ready.\nThanks"). Same answer as
    /// `CorrectionAlignment.continuesOnNewLine(_:afterToken:)`.
    func continuesOnNewLine(afterToken index: Int) -> Bool {
        guard index + 1 < ranges.count else { return false }
        let gap = bytes[ranges[index].upperBound..<ranges[index + 1].lowerBound]
        return String(decoding: gap, as: UTF8.self).contains { $0.isNewline }
    }

    // MARK: - Bytes

    private static func isASCIISpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }

    /// The lowercased key byte for an ASCII letter, digit or apostrophe; nil for anything else.
    private static func keyByte(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x61...0x7A, 0x30...0x39, 0x27: return byte
        case 0x41...0x5A: return byte + 0x20
        default: return nil
        }
    }

    private static func characterTokens(_ text: String) -> [String] { CorrectionAlignment.tokens(text) }

    private static func leadingWhitespaceBytes(in bytes: [UInt8], from offset: Int) -> Int {
        // Only the non-ASCII-whitespace separators inside a non-ASCII token need skipping here.
        var skipped = 0
        var scalarStart = offset
        while scalarStart < bytes.count {
            let length = scalarLength(bytes[scalarStart])
            guard scalarStart + length <= bytes.count else { break }
            let scalar = String(decoding: bytes[scalarStart..<(scalarStart + length)], as: UTF8.self)
            guard scalar.allSatisfy(\.isWhitespace) else { break }
            skipped += length
            scalarStart += length
        }
        return skipped
    }

    private static func scalarLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xF0...: return 4
        case 0xE0...: return 3
        case 0xC0...: return 2
        default: return 1
        }
    }
}
