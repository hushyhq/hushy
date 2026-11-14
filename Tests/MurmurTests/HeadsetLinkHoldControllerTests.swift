import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A key released while a Bluetooth headset's link was still coming up, through
/// `DictationController`: the recording is not recognised, and the pill says why.
@Suite("Headset link hold through the dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct HeadsetLinkHoldControllerTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    static let headset = InputDeviceInfo(name: "Dana's AirPods Pro", transport: .bluetooth, sampleRate: 16_000, channels: 1)
    static let mac = InputDeviceInfo(name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, channels: 1)

    /// `silence` ms of exact zeros, as a link coming up delivers, then `sound` ms of a clear tone.
    static func recording(silence: Int, sound: Int) -> [Float] {
        [Float](repeating: 0, count: silence * 16)
            + (0..<(sound * 16)).map { 0.2 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
    }

    private func harness(on device: InputDeviceInfo) throws -> Harness {
        let harness = try Harness()
        harness.controller.micFacts = { .init(device: device, builtInInput: "MacBook Pro Microphone", choice: nil) }
        return harness
    }

    @Test("released before the headset delivered any sound: the row says it was connecting, and nothing is recognised or saved")
    func releasedBeforeAnySound() async throws {
        let harness = try harness(on: Self.headset)
        harness.controller.finishForTests(samples: Self.recording(silence: 900, sound: 0))
        #expect(harness.pill.state == .failed(.headsetConnecting))
        #expect(!harness.controller.isBusy, "the next dictation is not blocked")
        #expect(harness.rows.isEmpty, "a link coming up is not a dictation")
    }

    @Test("released a moment after the link came up: a fragment is not sent to the recogniser")
    func releasedJustAfterTheLink() async throws {
        let harness = try harness(on: Self.headset)
        harness.controller.finishForTests(samples: Self.recording(silence: 1_100, sound: 200))
        #expect(harness.pill.state == .failed(.headsetConnecting))
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.pill.state == .failed(.headsetConnecting), "recognition never ran, so its failure never replaced the row")
        #expect(harness.rows.isEmpty)
    }

    @Test("speech after the link came up is recognised as usual")
    func speechAfterTheLinkIsRecognised() async throws {
        let harness = try harness(on: Self.headset)
        harness.controller.finishForTests(samples: Self.recording(silence: 1_100, sound: 1_500))
        // No model in the harness: reaching recognition shows as its failure row.
        #expect(await harness.eventually { harness.pill.state == .failed(.transcription(recordingKept: true)) })
    }

    @Test("the same short recording on the Mac's own microphone is not held: it has no link to wait for")
    func otherMicrophonesAreNotHeld() async throws {
        let harness = try harness(on: Self.mac)
        harness.controller.finishForTests(samples: Self.recording(silence: 900, sound: 0))
        #expect(harness.pill.state != .failed(.headsetConnecting))
    }

    @Test("a headset that stays silent for longer than a link takes is the quiet-microphone row, with its offer")
    func longSilenceIsStillTheQuietMicrophoneRow() async throws {
        let harness = try harness(on: Self.headset)
        harness.controller.finishForTests(samples: Self.recording(silence: 2_500, sound: 0))
        #expect(harness.pill.state == .failed(.quietMic(QuietMic(
            micName: "Dana's AirPods Pro", isSilent: true, betterInput: "MacBook Pro Microphone", soundsError: true, headsetSilence: true))))
    }

    @Test("the row for a headset that sent only zeros says so, and what to try")
    func silentHeadsetRowWords() {
        let row = DictationFailure.quietMic(QuietMic(
            micName: "Dana's AirPods Pro", isSilent: true, betterInput: "MacBook Pro Microphone", soundsError: true, headsetSilence: true))
        #expect(row.line == "Dana's AirPods Pro sent only silence")
        #expect(row.micOffer == "MacBook Pro Microphone", "and the Mac's microphone is still one tap away")
    }

    @Test("faint sound from a headset is not called silence: the row names the headset as before")
    func faintHeadsetIsNotSilence() throws {
        let harness = try harness(on: Self.headset)
        harness.controller.finishForTests(samples: [Float](repeating: 0.000_1, count: 48_000))
        #expect(harness.pill.state == .failed(.quietMic(QuietMic(
            micName: "Dana's AirPods Pro", isSilent: true, betterInput: "MacBook Pro Microphone"))))
    }
}
