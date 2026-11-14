import Foundation
import Testing
@testable import MurmurCore

/// Covers `VoiceEnrollment.enroll` (both the sync and async-extractor overloads) with a fake
/// embedding extractor — no FluidAudio dependency.
@Suite("VoiceEnrollment")
struct VoiceEnrollmentTests {
    @Test("averages multiple takes' embeddings into one unit-normalized signature")
    func averagesTakesIntoUnitVector() throws {
        let takes: [[Float]] = [[1, 2, 3], [4, 5, 6]]  // stand-ins for raw audio samples
        let embedding = try VoiceEnrollment.enroll(takes: takes) { take in
            // A fake extractor: turns the raw sample sum into a fixed-direction vector so the
            // test can assert on the *averaging*, not on any real embedding model.
            take == takes[0] ? [1, 0, 0] : [0, 1, 0]
        }
        let norm = embedding.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 0.0001)
        // Equal-weighted average of [1,0,0] and [0,1,0], normalized.
        #expect(abs(embedding[0] - embedding[1]) < 0.0001)
    }

    @Test("throws noSamples when every take is empty")
    func throwsOnAllEmptyTakes() {
        #expect(throws: VoiceEnrollment.EnrollmentError.noSamples) {
            _ = try VoiceEnrollment.enroll(takes: [[], []]) { _ in [1, 0] }
        }
    }

    @Test("throws noSamples when fewer takes than minimumTakes are usable")
    func throwsWhenBelowMinimumTakes() {
        #expect(throws: VoiceEnrollment.EnrollmentError.noSamples) {
            _ = try VoiceEnrollment.enroll(takes: [[1, 2, 3]], minimumTakes: 2) { _ in [1, 0] }
        }
    }

    @Test("skips takes whose extractor throws, succeeding on the remaining ones")
    func skipsFailedExtractions() throws {
        struct ExtractionFailure: Error {}
        let takes: [[Float]] = [[1], [2], [3]]
        let embedding = try VoiceEnrollment.enroll(takes: takes) { take in
            if take == [2] { throw ExtractionFailure() }
            return [1, 0]
        }
        #expect(embedding == [1, 0])
    }

    @Test("throws extractionFailed when every extraction fails")
    func throwsWhenAllExtractionsFail() {
        struct ExtractionFailure: Error {}
        #expect(throws: VoiceEnrollment.EnrollmentError.extractionFailed) {
            _ = try VoiceEnrollment.enroll(takes: [[1], [2]]) { _ in throw ExtractionFailure() }
        }
    }

    @Test("throws extractionFailed on mismatched embedding dimensions")
    func throwsOnMismatchedDimensions() {
        #expect(throws: VoiceEnrollment.EnrollmentError.extractionFailed) {
            _ = try VoiceEnrollment.enroll(takes: [[1], [2]]) { take in take == [1] ? [1, 0] : [1, 0, 0] }
        }
    }

    @Test("async overload produces the same result as the sync overload for equivalent input")
    func asyncOverloadMatchesSyncOverload() async throws {
        let takes: [[Float]] = [[1, 2], [3, 4]]
        let syncResult = try VoiceEnrollment.enroll(takes: takes) { $0 == takes[0] ? [1, 0] : [0, 1] }
        let asyncResult = try await VoiceEnrollment.enroll(takes: takes) { $0 == takes[0] ? [1, 0] : [0, 1] }
        #expect(syncResult == asyncResult)
    }
}
