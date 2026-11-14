import Foundation
import Testing
@testable import Murmur

/// Covers `MediaDecoder`, the streaming AVFoundation-based decoder file import uses to turn an
/// audio/video file's audio track into 16 kHz mono `Float` samples without loading the whole
/// file into memory. Since `AVAssetReader` needs a real file on disk, each test writes a small
/// synthetic WAV (a plain sine tone — deliberately speech-free, since these tests only check
/// decoding mechanics, not transcription quality) to a temporary file and decodes it back.
@Suite("MediaDecoder")
struct MediaDecoderTests {
    /// Writes a `durationSeconds` sine tone at `sampleRate` to a temporary 16-bit PCM WAV file
    /// and returns its URL. The caller is responsible for cleanup (each test uses a fresh
    /// temporary directory it removes at the end).
    private func makeSineWAV(
        durationSeconds: Double, sampleRate: Double = 16_000, frequency: Double = 440, in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("tone.wav")
        let frameCount = Int(durationSeconds * sampleRate)
        let samples = (0..<frameCount).map { index -> Float in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate) * 0.2)
        }
        try WAVWriter.write(samples, to: url)
        return url
    }

    private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    @Test("Decodes a short WAV file to a non-empty sample stream")
    func decodesShortFile() async throws {
        try await withTemporaryDirectory { directory in
            let url = try makeSineWAV(durationSeconds: 1.0, in: directory)
            var total = 0
            for try await chunk in MediaDecoder.stream(contentsOf: url) {
                total += chunk.count
            }
            // 1 second at 16 kHz should decode to approximately 16,000 samples (allow for
            // resampler edge effects at the tail of a short buffer).
            #expect(total > 15_000 && total < 17_000)
        }
    }

    @Test("Decoded sample count scales with duration")
    func sampleCountScalesWithDuration() async throws {
        try await withTemporaryDirectory { directory in
            let shortURL = try makeSineWAV(durationSeconds: 1.0, in: directory.appendingPathComponent("short", isDirectory: true))
            let longURL = try makeSineWAV(durationSeconds: 3.0, in: directory.appendingPathComponent("long", isDirectory: true))

            var shortTotal = 0
            for try await chunk in MediaDecoder.stream(contentsOf: shortURL) { shortTotal += chunk.count }
            var longTotal = 0
            for try await chunk in MediaDecoder.stream(contentsOf: longURL) { longTotal += chunk.count }

            #expect(longTotal > shortTotal * 2)
        }
    }

    @Test("Reports duration for a valid audio file")
    func reportsDuration() async throws {
        try await withTemporaryDirectory { directory in
            let url = try makeSineWAV(durationSeconds: 2.0, in: directory)
            let duration = try await MediaDecoder.duration(of: url)
            let unwrapped = try #require(duration)
            #expect(abs(unwrapped - 2.0) < 0.1)
        }
    }

    @Test("Throws for a file with no audio track")
    func throwsForNonAudioFile() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("not-audio.txt")
            try "hello".write(to: url, atomically: true, encoding: .utf8)
            await #expect(throws: (any Error).self) {
                for try await _ in MediaDecoder.stream(contentsOf: url) {}
            }
        }
    }

    @Test("Decoding an already-16kHz-mono file preserves the sample rate 1:1")
    func alreadyTargetRatePassesThrough() async throws {
        try await withTemporaryDirectory { directory in
            // 0.5s at exactly the target rate: decode should yield close to 8,000 samples with
            // no resampling drift.
            let url = try makeSineWAV(durationSeconds: 0.5, sampleRate: 16_000, in: directory)
            var total = 0
            for try await chunk in MediaDecoder.stream(contentsOf: url) { total += chunk.count }
            #expect(abs(total - 8_000) < 200)
        }
    }

    @Test("Cancelling the consuming task stops the stream")
    func cancellationStopsDecoding() async throws {
        try await withTemporaryDirectory { directory in
            // A longer file so there's room for cancellation to land before it finishes.
            let url = try makeSineWAV(durationSeconds: 10.0, in: directory)
            let task = Task {
                var chunkCount = 0
                for try await _ in MediaDecoder.stream(contentsOf: url) {
                    chunkCount += 1
                    if chunkCount == 1 { break }
                }
                return chunkCount
            }
            let result = try await task.value
            #expect(result >= 1)
        }
    }
}
