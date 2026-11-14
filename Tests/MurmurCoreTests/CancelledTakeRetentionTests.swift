import XCTest
@testable import MurmurCore

/// A cancelled take is a bounded safety net: it lasts a day, and there is a ceiling on how many are kept and
/// how much audio they hold. Everything else in History is untouched by it.
final class CancelledTakeRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> Store { try Store() }

    @discardableResult
    private func save(
        _ store: Store, _ status: Dictation.Status, minutesAgo: Double, seconds: Double = 5,
        text: String = "words", audio: String? = nil
    ) throws -> Dictation {
        try store.save(Dictation(
            createdAt: now.addingTimeInterval(-minutesAgo * 60), rawText: text, text: text,
            durationSeconds: seconds, status: status, audioPath: audio))
    }

    private func cancelled(_ store: Store) throws -> [Dictation] {
        try store.allDictations().filter { $0.status == .cancelled }
    }

    func testTheNewestTwentyTakesStayAndOlderOnesGoWithTheirAudio() throws {
        let store = try store()
        for minute in 0..<25 { try save(store, .cancelled, minutesAgo: Double(minute), audio: "/tmp/take-\(minute).wav") }
        let removed = try store.trimCancelledTakes()
        XCTAssertEqual(Set(removed), Set((20..<25).map { "/tmp/take-\($0).wav" }))
        let kept = try cancelled(store)
        XCTAssertEqual(kept.count, Store.cancelledTakeLimits.takes)
        XCTAssertTrue(kept.allSatisfy { $0.createdAt >= now.addingTimeInterval(-19 * 60) }, "the newest are the ones kept")
    }

    func testTheNewestTakeIsKeptEvenWhenItAloneIsOverTheAudioLimit() throws {
        let store = try store()
        try save(store, .cancelled, minutesAgo: 1, seconds: 5_000, audio: "/tmp/long.wav")
        try save(store, .cancelled, minutesAgo: 2, seconds: 60, audio: "/tmp/old.wav")
        let removed = try store.trimCancelledTakes()
        XCTAssertEqual(removed, ["/tmp/old.wav"])
        XCTAssertEqual(try cancelled(store).compactMap(\.audioPath), ["/tmp/long.wav"])
    }

    func testOlderTakesArePassedOverWhenTheAudioBudgetIsSpentButTextOnlyTakesAreFree() throws {
        let store = try store()
        let limits = Store.CancelledTakeLimits(takes: 20, audioSeconds: 100)
        try save(store, .cancelled, minutesAgo: 1, seconds: 60, audio: "/tmp/a.wav")
        try save(store, .cancelled, minutesAgo: 2, seconds: 60, audio: "/tmp/b.wav")
        try save(store, .cancelled, minutesAgo: 3, seconds: 600, text: "only words, audio was off")
        let removed = try store.trimCancelledTakes(keeping: limits)
        XCTAssertEqual(removed, ["/tmp/b.wav"])
        XCTAssertEqual(try cancelled(store).count, 2, "the text-only take costs no audio budget")
    }

    func testOtherRowsAreNeverTrimmed() throws {
        let store = try store()
        for minute in 0..<30 { try save(store, minute.isMultiple(of: 2) ? .inserted : .failed, minutesAgo: Double(minute), audio: "/tmp/x\(minute).wav") }
        XCTAssertEqual(try store.trimCancelledTakes(), [])
        XCTAssertEqual(try store.allDictations().count, 30)
    }

    func testTheDailySweepDropsATakeAfterADayAndKeepsARecentOne() throws {
        let store = try store()
        try save(store, .cancelled, minutesAgo: 23 * 60, audio: "/tmp/recent.wav")
        try save(store, .cancelled, minutesAgo: 25 * 60, audio: "/tmp/stale.wav")
        let removed = try store.applyRetention(audioDays: nil, textDays: nil, now: now)
        XCTAssertEqual(removed, ["/tmp/stale.wav"])
        XCTAssertEqual(try cancelled(store).compactMap(\.audioPath), ["/tmp/recent.wav"])
    }

    func testTheSweepKeepsATakeThePersonRecoveredForTheHistoryWindow() throws {
        let store = try store()
        var take = try save(store, .cancelled, minutesAgo: 30 * 60, audio: "/tmp/mine.wav")
        take.status = .notInserted
        _ = try store.save(take)
        XCTAssertEqual(try store.applyRetention(audioDays: nil, textDays: 30, now: now), [])
        XCTAssertEqual(try store.allDictations().count, 1)
    }

    func testAnUnlandedPasteStopsSayingInsertedAndOnlyThen() throws {
        let store = try store()
        let pasted = try save(store, .inserted, minutesAgo: 1)
        let failed = try save(store, .failed, minutesAgo: 2)
        let recovered = try save(store, .notInserted, minutesAgo: 3)
        for row in [pasted, failed, recovered] { try store.markUnlandedPaste(id: try XCTUnwrap(row.id)) }
        let statuses = Dictionary(uniqueKeysWithValues: try store.allDictations().map { ($0.id!, $0.status) })
        XCTAssertEqual(statuses[pasted.id!], .notInserted)
        XCTAssertEqual(statuses[failed.id!], .failed, "a row that is not inserted is left as it is")
        XCTAssertEqual(statuses[recovered.id!], .notInserted)
        XCTAssertTrue(HistoryAttention.isActionable(try XCTUnwrap(try store.allDictations().first { $0.id == pasted.id })),
                      "and History now lists it as something to recover")
    }
}
