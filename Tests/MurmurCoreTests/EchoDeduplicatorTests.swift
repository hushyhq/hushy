import Foundation
import Testing
@testable import MurmurCore

/// Covers `EchoDeduplicator.deduplicate`, the pure text+timing rule that drops mic words which
/// are actually system-audio bleed-through — see the task's contract: "when both streams contain
/// the same words at nearly the same time, drop the mic copy."
@Suite("Echo deduplicator")
struct EchoDeduplicatorTests {
    @Test("drops a mic word that matches a system word at nearly the same time")
    func dropsMatchingWordAtSameTime() {
        let mic = [StreamWord(word: "hello", start: 1.0, end: 1.4, stream: .microphone)]
        let system = [StreamWord(word: "hello", start: 1.05, end: 1.45, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.isEmpty)
    }

    @Test("keeps a mic word with no timing-close match in the system stream")
    func keepsUnmatchedWord() {
        let mic = [StreamWord(word: "hello", start: 1.0, end: 1.4, stream: .microphone)]
        let system = [StreamWord(word: "hello", start: 10.0, end: 10.4, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.count == 1)
        #expect(result[0].word == "hello")
    }

    @Test("keeps a mic word that is close in time but a different word")
    func keepsDifferentWordAtSameTime() {
        let mic = [StreamWord(word: "yes", start: 1.0, end: 1.4, stream: .microphone)]
        let system = [StreamWord(word: "hello", start: 1.05, end: 1.45, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.count == 1)
    }

    @Test("word match just outside the time tolerance is kept")
    func keepsWordOutsideTolerance() {
        let mic = [StreamWord(word: "hello", start: 1.0, end: 1.4, stream: .microphone)]
        // Mic midpoint 1.2, system midpoint 1.2 + 0.4 = 1.6 -> 0.4s apart, beyond the 0.35s default.
        let system = [StreamWord(word: "hello", start: 1.6, end: 2.0, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.count == 1)
    }

    @Test("word match just inside the time tolerance is dropped")
    func dropsWordInsideTolerance() {
        let mic = [StreamWord(word: "hello", start: 1.0, end: 1.4, stream: .microphone)]
        // Mic midpoint 1.2, system midpoint 1.2 + 0.3 = 1.5 -> 0.3s apart, within the 0.35s default.
        let system = [StreamWord(word: "hello", start: 1.3, end: 1.7, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.isEmpty)
    }

    @Test("matching is case-insensitive and ignores punctuation")
    func normalizesTextBeforeComparing() {
        let mic = [StreamWord(word: "Hello,", start: 1.0, end: 1.4, stream: .microphone)]
        let system = [StreamWord(word: "hello", start: 1.05, end: 1.45, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.isEmpty)
    }

    @Test("only drops the matching word, keeping the rest of the mic sentence")
    func dropsOnlyMatchingWord() {
        let mic = [
            StreamWord(word: "I", start: 0.0, end: 0.2, stream: .microphone),
            StreamWord(word: "said", start: 0.2, end: 0.5, stream: .microphone),
            StreamWord(word: "hello", start: 0.5, end: 0.9, stream: .microphone),
        ]
        let system = [StreamWord(word: "hello", start: 0.55, end: 0.95, stream: .systemAudio)]
        let result = EchoDeduplicator.deduplicate(mic: mic, systemAudio: system)
        #expect(result.map(\.word) == ["I", "said"])
    }

    @Test("empty mic or system input returns mic unchanged")
    func handlesEmptyInputs() {
        #expect(EchoDeduplicator.deduplicate(mic: [], systemAudio: []).isEmpty)
        let mic = [StreamWord(word: "hi", start: 0, end: 0.2, stream: .microphone)]
        #expect(EchoDeduplicator.deduplicate(mic: mic, systemAudio: []) == mic)
    }

    @Test("normalize lowercases and strips punctuation")
    func normalizeHelper() {
        #expect(EchoDeduplicator.normalize("Hello,") == "hello")
        #expect(EchoDeduplicator.normalize("IT'S") == "its")
        #expect(EchoDeduplicator.normalize("") == "")
    }
}
