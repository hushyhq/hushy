import Foundation
import Testing
@testable import MurmurCore

/// Chat boxes that empty on send, after the person fixed the dictation (`Fixtures/learning-replay-chat-send.jsonl`,
/// written by `scripts/learning_replay_chat_send_gen.py`; every session is invented). Claude, ChatGPT (app and web),
/// Slack and Messages, with the fix made where the schedule's looks are sparse, sent with Return or a click, typed
/// letter by letter, or undoing Hushy's own swap. Scored like the main replay set, with and without change reads.
///
/// `LEARNING_REPLAY_OUT=<file>` also writes the metrics lines and every miss there (appends to the main set's file).
@Suite("Learning · chat boxes that empty on send")
struct ChatSendReplayTests {
    /// The one session no read can help: the field never reports a change and the fix sits between two scheduled
    /// looks before a click on Send. It stays missed until a read of the sent message exists.
    static let knownMisses: Set<String> = ["chatgpt-web-no-reports"]

    @Test("change reads learn the fixes the schedule alone loses, and teach nothing the person did not mean")
    func chatSend() throws {
        let sessions = try LearningReplayTests.load("learning-replay-chat-send.jsonl")
        #expect(sessions.count >= 30)
        let before = LearningReplayTests.score(sessions, reader: .init(usesChangeReads: false))
        let after = LearningReplayTests.score(sessions)
        let report = (["chat-send before (schedule + Return read) \(before)", "chat-send after (+ change reads) \(after)"]
            + after.misses.map { "chat-send miss \($0)" }).joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["LEARNING_REPLAY_OUT"] {
            let earlier = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            try (earlier + (earlier.isEmpty ? "" : "\n") + report).write(toFile: out, atomically: true, encoding: .utf8)
        }
        let lessons = sessions.reduce(0) { $0 + $1.expect.count }
        #expect(after.falsePositive == 0, "no lesson the person did not mean")
        #expect(after.mislabelled == 0, "a message sent as it was pasted says unchanged")
        #expect(after.truePositive == lessons - Self.knownMisses.count, "every fix but the known miss is learned")
        #expect(before.truePositive < after.truePositive, "the schedule alone loses fixes sent from a box that empties")
        #expect(before.falsePositive == 0)
        let missed = Set(after.misses.compactMap { $0.split(separator: " ").first.map(String.init) })
        #expect(missed == Self.knownMisses, "\(after.misses)")
    }

    @Test("per kind of session, what the schedule alone learns and what change reads add")
    func perKind() throws {
        let sessions = try LearningReplayTests.load("learning-replay-chat-send.jsonl")
        // A fix sent with a click between two sparse looks, or after a Return the native app empties the box on, is
        // lost today; with change reads it is learned. Chromium boxes empty after the Return read, so it already sees it.
        for session in sessions where !session.expect.isEmpty && !Self.knownMisses.contains(session.id) {
            let before = LearningReplayTests.score([session], reader: .init(usesChangeReads: false))
            let after = LearningReplayTests.score([session])
            #expect(after.truePositive == session.expect.count, "\(session.id): \(after.misses)")
            let clickOrNative = session.returnAt == nil || session.returnReadLag != nil
            if clickOrNative { #expect(before.truePositive == 0, "\(session.id) is lost without change reads") }
        }
    }
}
