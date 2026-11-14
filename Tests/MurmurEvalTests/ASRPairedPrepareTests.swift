import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Testing

@testable import murmur_eval

@Suite("Paired ASR preparation")
struct ASRPairedPrepareTests {
    @Test func prepareRejectsNonScoringSentinelBeforeOpeningAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("asr-paired-sentinel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let casesURL = root.appendingPathComponent("cases.json")
        let cases: [String: Any] = ["schema_version": 1, "clips": [[
            "id": "sentinel", "reference": "ignore_time_segment_in_scoring", "category": "accent",
        ]]]
        try JSONSerialization.data(withJSONObject: cases).write(to: casesURL)
        let out = root.appendingPathComponent("prepared", isDirectory: true)
        let args = Arguments(["asr-paired", "prepare", "--cases", casesURL.path, "--out-dir", out.path][...])
        do {
            try await ASRPairedRunner.run(args)
            Issue.record("expected the reserved non-scoring transcript sentinel to be rejected")
        } catch let error as ASRPairedValidationError {
            #expect(error.errorDescription?.contains("non-scoring") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func prepareWritesHashedMono16kWavThatTheRecognizerAudioReaderCanDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("asr-paired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAudio = root.appendingPathComponent("source.wav")
        let samples = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000) * 0.2) }
        try EvalWAV.write(samples, to: sourceAudio)
        let casesURL = root.appendingPathComponent("cases.json")
        let cases: [String: Any] = ["schema_version": 1, "clips": [[
            "id": "one", "audio_path": sourceAudio.path, "reference": "a tone",
            "cleaned_reference": "A tone.", "group": "fixture", "category": "audio",
        ]]]
        try JSONSerialization.data(withJSONObject: cases).write(to: casesURL)
        let output = root.appendingPathComponent("prepared", isDirectory: true)
        let args = Arguments(["asr-paired", "prepare", "--cases", casesURL.path, "--out-dir", output.path][...])
        try await ASRPairedRunner.run(args)

        let manifestURL = output.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(ASRPairedManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.clips.count == 1)
        let clip = try #require(manifest.clips.first)
        let audioURL = URL(fileURLWithPath: clip.audio_path)
        let audioData = try Data(contentsOf: audioURL)
        #expect(SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined() == clip.audio_sha256)
        let decoded = try AudioConverter().resampleAudioFile(audioURL)
        #expect(decoded.count == samples.count)
        #expect(clip.cleaned_reference == "A tone.")
    }
}
