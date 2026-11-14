import XCTest
@testable import MurmurCore

final class DictationRecoveryTests: XCTestCase {
    private func take(_ status: Dictation.Status, text: String, audio: String?) -> Dictation {
        Dictation(rawText: text, text: text, durationSeconds: 4, status: status, audioPath: audio)
    }

    func testARowWithWordsIsCopied() {
        for status: Dictation.Status in [.cancelled, .failed, .notInserted, .inserted] {
            XCTAssertEqual(DictationRecovery.action(for: take(status, text: "Ship it.", audio: nil)), .copy, "\(status)")
        }
    }

    func testACancelledOrFailedTakeWithAudioAndNoWordsIsReadAgain() {
        XCTAssertEqual(DictationRecovery.action(for: take(.cancelled, text: "", audio: "/tmp/a.wav")), .retryTranscription)
        XCTAssertEqual(DictationRecovery.action(for: take(.failed, text: "", audio: "/tmp/a.wav")), .retryTranscription)
    }

    func testATakeWithNeitherWordsNorAudioHasNothingToGetBack() {
        XCTAssertEqual(DictationRecovery.action(for: take(.cancelled, text: "", audio: nil)), .none)
        XCTAssertEqual(DictationRecovery.action(for: take(.failed, text: "", audio: nil)), .none)
    }

    func testAPastedOrUnpastedRowWithNoWordsIsNotRetried() {
        XCTAssertEqual(DictationRecovery.action(for: take(.inserted, text: "", audio: "/tmp/a.wav")), .none)
        XCTAssertEqual(DictationRecovery.action(for: take(.notInserted, text: "", audio: "/tmp/a.wav")), .none)
    }
}
