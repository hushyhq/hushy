import Foundation
import Testing
@testable import MurmurCore

@Suite("HistoryAttention")
struct HistoryAttentionTests {
    private let seen = Date(timeIntervalSince1970: 1_800_000_000)
    private var after: Date { seen.addingTimeInterval(60) }
    private var before: Date { seen.addingTimeInterval(-60) }

    private func dictation(
        _ status: Dictation.Status, text: String = "", raw: String = "", audio: String? = nil, at date: Date? = nil
    ) -> Dictation {
        Dictation(createdAt: date ?? after, rawText: raw, text: text, durationSeconds: 1, status: status, audioPath: audio)
    }

    @Test("not-pasted dictations with text are actionable")
    func notPastedWithText() {
        #expect(HistoryAttention.isActionable(dictation(.notInserted, text: "Call Sam back")))
    }

    @Test("not-pasted with no text (e.g. a bare Return) is not actionable")
    func notPastedBlank() {
        #expect(!HistoryAttention.isActionable(dictation(.notInserted, text: "  \n")))
    }

    @Test("failed with saved audio, a raw transcript, or cleaned text is actionable")
    func failedRecoverable() {
        #expect(HistoryAttention.isActionable(dictation(.failed, audio: "/tmp/a.caf")))
        #expect(HistoryAttention.isActionable(dictation(.failed, raw: "original words")))
        #expect(HistoryAttention.isActionable(dictation(.failed, text: "cleaned words")))
    }

    @Test("failed with nothing left to recover is not actionable")
    func failedDeadEnd() {
        #expect(!HistoryAttention.isActionable(dictation(.failed)))
    }

    @Test("cancelled and inserted dictations are never actionable")
    func cancelledAndInserted() {
        #expect(!HistoryAttention.isActionable(dictation(.cancelled, raw: "never mind", audio: "/tmp/a.caf")))
        #expect(!HistoryAttention.isActionable(dictation(.inserted, text: "landed fine")))
    }

    @Test("badge counts only actionable dictations newer than the last History visit")
    func badgeCountsOnlyUnseenActionable() {
        let items = [
            dictation(.notInserted, text: "new, not pasted"),         // counts
            dictation(.failed, audio: "/tmp/b.caf"),                   // counts
            dictation(.failed),                                        // dead end
            dictation(.cancelled, raw: "oops"),                        // deliberate
            dictation(.inserted, text: "fine"),                        // fine
            dictation(.notInserted, text: "old, already seen", at: before), // seen
            dictation(.failed, audio: "/tmp/c.caf", at: seen),         // exactly at the mark = seen
        ]
        #expect(HistoryAttention.badgeCount(items, seenThrough: seen) == 2)
    }

    @Test("visiting History (moving the seen mark to now) clears the badge")
    func visitingClears() {
        let items = [dictation(.notInserted, text: "a"), dictation(.failed, raw: "b")]
        #expect(HistoryAttention.badgeCount(items, seenThrough: seen) == 2)
        #expect(HistoryAttention.badgeCount(items, seenThrough: after.addingTimeInterval(1)) == 0)
    }

    @Test("a dictation that fails after the visit brings the badge back for just that one")
    func newFailureAfterVisit() {
        let visit = after.addingTimeInterval(1)
        let items = [
            dictation(.notInserted, text: "seen"),
            dictation(.failed, audio: "/tmp/d.caf", at: visit.addingTimeInterval(30)),
        ]
        #expect(HistoryAttention.badgeCount(items, seenThrough: visit) == 1)
    }

    @Test("recovering a failed row that was already seen doesn't re-inflate the count")
    func recoveredSeenRowStaysCleared() {
        var item = dictation(.cancelled, raw: "recover me", at: before)
        item.status = .notInserted
        item.text = "recover me"
        #expect(HistoryAttention.badgeCount([item], seenThrough: seen) == 0)
    }
}
