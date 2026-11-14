import Compression
import Foundation
import Testing

@testable import murmur_eval

/// Covers `Zlib.inflateRaw`, the raw-DEFLATE decompression `RangeZipReader` uses to inflate a
/// single ZIP entry fetched via HTTP Range requests (see VoxConverseDownloader.swift). Uses
/// `compression_encode_buffer` (the encode counterpart of what `inflateRaw` decodes) to build
/// fixtures, so this test has no dependency on any real ZIP file or network access.
@Suite("Zlib.inflateRaw")
struct ZlibTests {
    private func rawDeflate(_ text: String) -> Data {
        let source = Array(text.utf8)
        var destination = [UInt8](repeating: 0, count: source.count * 2 + 64)
        let count = source.withUnsafeBufferPointer { sourceBuffer -> Int in
            compression_encode_buffer(
                &destination, destination.count, sourceBuffer.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
        return Data(destination[0..<count])
    }

    @Test("inflates a small raw-DEFLATE payload back to its original text")
    func inflatesSmallPayload() throws {
        let original = "hello world, this is a small test payload"
        let compressed = rawDeflate(original)
        let inflated = try Zlib.inflateRaw(compressed)
        #expect(String(data: inflated, encoding: .utf8) == original)
    }

    @Test("inflates a payload larger than the initial capacity guess, growing the buffer")
    func inflatesLargePayloadRequiringGrowth() throws {
        // Highly repetitive text compresses far smaller than 4x, which is `inflateRaw`'s first
        // capacity guess when no expectedSize is given — this exercises the growth loop.
        let original = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 5000)
        let compressed = rawDeflate(original)
        #expect(compressed.count * 4 < original.utf8.count)  // confirms this actually tests growth
        let inflated = try Zlib.inflateRaw(compressed)
        #expect(String(data: inflated, encoding: .utf8) == original)
    }

    @Test("an expectedSize hint that's already correct still inflates correctly")
    func expectedSizeHintWorks() throws {
        let original = "a payload with a known exact size hint"
        let compressed = rawDeflate(original)
        let inflated = try Zlib.inflateRaw(compressed, expectedSize: original.utf8.count)
        #expect(String(data: inflated, encoding: .utf8) == original)
    }

    @Test("a truncated/corrupt DEFLATE stream throws rather than returning corrupt data")
    func truncatedStreamThrows() {
        let original = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 200)
        let compressed = rawDeflate(original)
        // Truncate to a third of its length — a well-formed DEFLATE stream cut off mid-block,
        // which cannot decode to a plausible amount of output within the given capacity guess.
        let truncated = compressed.prefix(compressed.count / 3)
        #expect(throws: Error.self) {
            try Zlib.inflateRaw(Data(truncated), expectedSize: original.utf8.count)
        }
    }
}
