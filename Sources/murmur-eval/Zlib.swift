import Compression
import Foundation

/// Raw DEFLATE decompression (no zlib/gzip framing), matching ZIP's compression method 8, via
/// Apple's `Compression` framework (`COMPRESSION_ZLIB`'s raw-deflate mode) — no external zlib
/// dependency needed. Used only by `RangeZipReader` to inflate a single ZIP entry fetched via
/// HTTP Range requests (see `VoxConverseDownloader.swift`).
enum Zlib {
    enum ZlibError: LocalizedError {
        case decompressionFailed
        var errorDescription: String? { "Raw DEFLATE decompression failed" }
    }

    /// Inflates `compressed` (raw DEFLATE stream). The destination buffer grows geometrically
    /// until decompression completes, since ZIP's central directory does give an uncompressed
    /// size the caller could pass instead — kept simple here since VoxConverse WAV entries are a
    /// known, bounded size (tens of MB).
    static func inflateRaw(_ compressed: Data, expectedSize: Int? = nil) throws -> Data {
        var capacity = expectedSize ?? max(compressed.count * 4, 1 << 20)
        while true {
            if let result = try? attemptInflate(compressed, capacity: capacity) {
                return result
            }
            capacity *= 2
            if capacity > 1 << 31 { throw ZlibError.decompressionFailed }
        }
    }

    private static func attemptInflate(_ compressed: Data, capacity: Int) throws -> Data {
        var destination = [UInt8](repeating: 0, count: capacity)
        let decodedCount = compressed.withUnsafeBytes { sourcePointer -> Int in
            guard let sourceBase = sourcePointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                &destination, capacity, sourceBase, compressed.count, nil, COMPRESSION_ZLIB)
        }
        guard decodedCount > 0, decodedCount < capacity else { throw ZlibError.decompressionFailed }
        return Data(destination[0..<decodedCount])
    }
}
