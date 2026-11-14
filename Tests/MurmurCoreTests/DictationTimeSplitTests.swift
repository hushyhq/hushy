import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// The time split kept with each History entry: seconds with one decimal, the stages that add up to the
/// total, and rows saved before the split existed.
@Suite("Dictation time split", .timeLimit(.minutes(1)))
struct DictationTimeSplitTests {
    private func trace(secondPassMs: Int?, source: SmartCleaner.GroupSource? = nil) -> GroupTrace {
        GroupTrace(
            words: 20, outcome: .used, guardCode: nil, edited: true, modelMs: 900,
            secondPass: secondPassMs == nil ? SecondPass.none : .used, source: source, secondPassMs: secondPassMs)
    }

    @Test("times show as seconds with one decimal")
    func seconds() {
        #expect(DictationTimeSplit.seconds(5_700) == "5.7 s")
        #expect(DictationTimeSplit.seconds(400) == "0.4 s")
        #expect(DictationTimeSplit.seconds(0) == "0.0 s")
        #expect(DictationTimeSplit.seconds(12_345) == "12.3 s")
        #expect(DictationTimeSplit.seconds(-5) == "0.0 s")
    }

    @Test("the line names the stages after release, with the second pass only when it ran")
    func line() {
        let plain = DictationTimeSplit(speechMs: 3_900, cleanupMs: 1_400, insertMs: 400)
        #expect(plain.plainLine(totalMs: 5_700) == "After release: recognition 3.9 s · cleanup 1.4 s · typing 0.4 s")
        let second = DictationTimeSplit(speechMs: 3_900, cleanupMs: 800, secondPassMs: 600, insertMs: 400)
        #expect(second.plainLine(totalMs: 5_700)
            == "After release: recognition 3.9 s · cleanup 0.8 s · second cleanup pass 0.6 s · typing 0.4 s")
    }

    @Test("rounded on their own the parts would not add up to the total; shown, they do")
    func partsAddUpToTheTotal() {
        // 1.04 s three times is 3.12 s: each rounds to 1.0 s but the total rounds to 3.1 s.
        let split = DictationTimeSplit(speechMs: 1_040, cleanupMs: 1_040, insertMs: 1_040)
        let tenths = split.displayedTenths(totalMs: 3_120)
        #expect(tenths.reduce(0, +) == 31)
        #expect(DictationTimeSplit.seconds(3_120) == "3.1 s")
        #expect(split.plainLine(totalMs: 3_120) == "After release: recognition 1.1 s · cleanup 1.0 s · typing 1.0 s")
    }

    @Test("for any split the shown parts add up to the shown total, and none moves by more than a tenth")
    func partsAddUpEverywhere() {
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for _ in 0..<2_000 {
            let speech = next(8_000), cleanup = next(4_000), insert = next(1_500)
            let second: Int? = next(3) == 0 ? next(cleanup + 1) : nil
            let split = DictationTimeSplit(speechMs: speech, cleanupMs: cleanup - (second ?? 0), secondPassMs: second, insertMs: insert)
            let total = speech + cleanup + insert + next(4)   // the stage marks truncate, so the total can be a few ms more
            let tenths = split.displayedTenths(totalMs: total)
            #expect(tenths.reduce(0, +) == Int((Double(total) / 100).rounded()))
            #expect(DictationTimeSplit.seconds(total) == "\(tenths.reduce(0, +) / 10).\(tenths.reduce(0, +) % 10) s")
            let exact = [speech, cleanup - (second ?? 0)] + (second.map { [$0] } ?? []) + [insert]
            for (shown, ms) in zip(tenths, exact) { #expect(abs(Double(shown) - Double(ms) / 100) <= 1.5) }
        }
    }

    @Test("a zero total falls back to the parts' own sum")
    func zeroTotal() {
        let split = DictationTimeSplit(speechMs: 300, cleanupMs: 200, insertMs: 100)
        #expect(split.plainLine(totalMs: 0) == "After release: recognition 0.3 s · cleanup 0.2 s · typing 0.1 s")
    }

    @Test("the second pass is taken out of the cleanup stage so the figures add up")
    func secondPassSplitOut() {
        let split = DictationTimeSplit(
            speechMs: 3_000, cleanupStageMs: 1_400, insertMs: 300, groups: [trace(secondPassMs: 600)])
        #expect(split.cleanupMs == 800)
        #expect(split.secondPassMs == 600)
        #expect(split.speechMs + split.cleanupMs + (split.secondPassMs ?? 0) + split.insertMs == 3_000 + 1_400 + 300)
    }

    @Test("a group still being waited on at release keeps its wait in cleanup, not in the second pass")
    func awaitedAtRelease() {
        // Its second pass took 700 ms in all, some of it before the release: how much is not recorded.
        let awaited = DictationTimeSplit(
            speechMs: 2_000, cleanupStageMs: 900, insertMs: 100, groups: [trace(secondPassMs: 700, source: .prewarmAwaited)])
        #expect(awaited.secondPassMs == nil)
        #expect(awaited.cleanupMs == 900)
        // Beside a group cleaned after the release, only that group's second pass counts.
        let mixed = DictationTimeSplit(
            speechMs: 2_000, cleanupStageMs: 1_500, insertMs: 100,
            groups: [trace(secondPassMs: 700, source: .prewarmAwaited), trace(secondPassMs: 400, source: .fresh)])
        #expect(mixed.secondPassMs == 400)
        #expect(mixed.cleanupMs == 1_100)
        // A short dictation has no source and was cleaned after the release.
        let short = DictationTimeSplit(speechMs: 1, cleanupStageMs: 1_000, insertMs: 1, groups: [trace(secondPassMs: 400)])
        #expect(short.secondPassMs == 400)
    }

    @Test("a second pass is added to the model time and kept apart, from the durations given")
    func secondPassDurations() {
        let first = GroupTrace(words: 20, outcome: .used, guardCode: nil, edited: false, modelMs: 900)
        let after = first.afterSecondPass(.used, took: .milliseconds(600), outcome: .used, guardCode: .some(nil), widenedOnly: false)
        #expect(after.secondPassMs == 600)
        #expect(after.modelMs == 1_500)
        #expect(after.secondPass == .used)
        let noFirstTime = GroupTrace(words: 20, outcome: .used, guardCode: nil, edited: false, modelMs: nil)
        #expect(noFirstTime.afterSecondPass(.kept, took: .milliseconds(250), widenedOnly: false).modelMs == 250)
        #expect(first.secondPassMs == nil)
    }

    @Test("no second pass, or one that was served from the prewarm, shows no second-pass figure")
    func noSecondPassFigure() {
        let none = DictationTimeSplit(speechMs: 1, cleanupStageMs: 500, insertMs: 1, groups: [trace(secondPassMs: nil)])
        #expect(none.secondPassMs == nil)
        #expect(none.cleanupMs == 500)
        let prewarmed = DictationTimeSplit(
            speechMs: 1, cleanupStageMs: 500, insertMs: 1, groups: [trace(secondPassMs: 700, source: .prewarmHit)])
        #expect(prewarmed.secondPassMs == nil)
        #expect(prewarmed.cleanupMs == 500)
    }

    @Test("the second pass never exceeds the cleanup stage")
    func cappedAtStage() {
        let split = DictationTimeSplit(
            speechMs: 1, cleanupStageMs: 300, insertMs: 1, groups: [trace(secondPassMs: 900), trace(secondPassMs: 900)])
        #expect(split.secondPassMs == 300)
        #expect(split.cleanupMs == 0)
    }

    @Test("the split is saved with the History entry and read back")
    func saved() throws {
        let store = try Store()
        let split = DictationTimeSplit(speechMs: 3_900, cleanupMs: 800, secondPassMs: 600, insertMs: 400)
        let saved = try store.save(Dictation(rawText: "a", text: "A", durationSeconds: 1, latencyMs: 5_700, timeSplit: split))
        #expect(saved.timeSplit == split)
        #expect(try store.lastDictation()?.timeSplit == split)
        let withoutSecond = DictationTimeSplit(speechMs: 100, cleanupMs: 50, insertMs: 30)
        _ = try store.save(Dictation(rawText: "b", text: "B", durationSeconds: 1, timeSplit: withoutSecond))
        #expect(try store.lastDictation()?.timeSplit == withoutSecond)
        #expect(try store.lastDictation()?.timeSplit?.secondPassMs == nil)
    }

    @Test("a row saved before the split existed still reads, with its total and no split")
    func olderRow() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue)
        let column = try queue.read { try $0.columns(in: "dictation") }.first { $0.name == "timeSplit" }
        #expect(column != nil)
        #expect(column?.isNotNull == false)
        // An older build's INSERT names only the columns it knows.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation (createdAt, rawText, text, appBundleID, appName, durationSeconds, wordCount, latencyMs, fixes, status)
                VALUES (?, 'raw', 'text', 'com.example.App', 'Example', 2.0, 1, 5700, 0, 'inserted')
                """, arguments: [Date()])
        }
        let row = try #require(try queue.read { try Dictation.fetchOne($0) })
        #expect(row.timeSplit == nil)
        #expect(DictationTimeSplit.seconds(row.latencyMs) == "5.7 s")
    }
}
