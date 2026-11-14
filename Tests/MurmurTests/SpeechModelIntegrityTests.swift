import FluidAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@Suite("Speech model checksum verification")
struct SpeechModelIntegrityTests {
    private struct Offline: Error {}

    private func modelDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-integrity-\(UUID().uuidString)")
        let weights = directory.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: weights)
        try Data("hello world".utf8).write(to: directory.appendingPathComponent("config.json"))
        return directory
    }

    private func integrity(_ entries: [ChecksumManifest.Entry]?) -> SpeechModelIntegrity {
        SpeechModelIntegrity(fetchManifest: { _ in
            guard let entries else { throw Offline() }
            return ChecksumManifest(entries: entries)
        }, defaultsSuiteName: "hushy-integrity-tests-\(UUID().uuidString)")
    }

    private let good = [
        ChecksumManifest.Entry(path: "Encoder.mlmodelc/weights/weight.bin", size: 11,
                               digest: .sha256("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")),
        ChecksumManifest.Entry(path: "config.json", size: 11, digest: .gitBlobSHA1("95d09f2b10159347eece71399a7e2e907ea3df4f")),
    ]

    @Test("matching files verify")
    func verified() async throws {
        let outcome = await integrity(good).verify(version: .ultra, directory: try modelDirectory())
        #expect(outcome == .verified(2))
    }

    @Test("a corrupted weight file is reported and its whole model folder removed for re-download")
    func corrupted() async throws {
        let directory = try modelDirectory()
        var bad = good
        bad[0] = ChecksumManifest.Entry(path: bad[0].path, size: 11, digest: .sha256(String(repeating: "0", count: 64)))
        let outcome = await integrity(bad).verify(version: .ultra, directory: directory)
        #expect(outcome == .corrupted(["Encoder.mlmodelc/weights/weight.bin"]))
        SpeechModelIntegrity.removeCorrupted(["Encoder.mlmodelc/weights/weight.bin"], in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Encoder.mlmodelc").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
    }

    @Test("no listing (offline) leaves it unverified, not failed; pending survives until verified")
    func unverified() async throws {
        let check = integrity(nil)
        check.markPending(.ultra)
        let outcome = await check.verify(version: .ultra, directory: try modelDirectory())
        if case .unverified = outcome {} else { Issue.record("expected unverified, got \(outcome)") }
        #expect(check.isPending(.ultra))
        check.clearPending(.ultra)
        #expect(!check.isPending(.ultra))
    }

    @Test("follows Hugging Face's Link paging header")
    func paging() {
        let link = "<https://huggingface.co/api/models/x/tree/main?recursive=true&cursor=abc>; rel=\"next\""
        #expect(HuggingFaceChecksums.nextPage(from: link)?.absoluteString == "https://huggingface.co/api/models/x/tree/main?recursive=true&cursor=abc")
        #expect(HuggingFaceChecksums.nextPage(from: nil) == nil)
        #expect(HuggingFaceChecksums.nextPage(from: "<https://a>; rel=\"prev\"") == nil)
    }
}
