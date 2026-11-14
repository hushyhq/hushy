import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Every watched dictation ends with exactly one `learning` line that says what became of it.
/// The field is scripted, the database in memory, and every sentence invented.
@Suite("Edit watcher reasons")
@MainActor
struct EditWatcherReasonTests {
    private let app = "com.brave.Browser"
    private let inserted = "please send the Velorya report to the whole team before noon today"
    private var fixed: String { inserted.replacingOccurrences(of: "Velorya", with: "Veloria") }

    /// The diagnoses a watch reported, in order.
    final class Heard {
        var all: [LearningDiagnosis] = []
    }

    /// Watches one pasted dictation whose field reads as `field(look)` (1 is the first look).
    private func watch(
        _ text: String? = nil, store: Store, learning: Bool = true, context: LearningContext? = nil,
        refusal: LearningRefusal? = nil, isStillAllowed: @escaping @MainActor () -> Bool = { true },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in },
        field: @escaping @MainActor (Int) -> EditWatcher.ReadResult
    ) async throws -> [LearningDiagnosis] {
        let text = text ?? inserted
        let id = try #require(store.save(Dictation(rawText: text, text: text, appBundleID: app, durationSeconds: 1)).id)
        let heard = Heard()
        var looks = 0
        let input = EditWatcher.LearningInput(raw: text, context: context ?? LearningContext(appBundleID: app), isStillAllowed: isStillAllowed)
        await EditWatcher.observe(
            inserted: text, dictationID: id, store: store, learning: learning ? input : nil, refusal: refusal, app: app,
            report: { heard.all.append($0) },
            readField: {
                looks += 1
                return field(looks)
            }, sleep: sleep).value
        return heard.all
    }

    private func observed(_ value: String) -> EditWatcher.ReadResult { .init(fieldValue: value, coverage: .observed) }
    private var unreadable: EditWatcher.ReadResult { .init(fieldValue: nil, coverage: .fieldUnreadable) }

    /// The dictation as pasted on the first two looks, then `later`.
    private func then(_ later: String) -> @MainActor (Int) -> EditWatcher.ReadResult {
        let pasted = inserted
        return { $0 <= 2 ? .init(fieldValue: pasted, coverage: .observed) : .init(fieldValue: later, coverage: .observed) }
    }

    private func one(_ heard: [LearningDiagnosis]) throws -> LearningDiagnosis {
        #expect(heard.count == 1)
        return try #require(heard.first)
    }

    @Test("no field to look at: unreadable from the start, said at once")
    func noElement() throws {
        let store = try Store()
        let id = try #require(store.save(Dictation(rawText: inserted, text: inserted, appBundleID: app, durationSeconds: 1)).id)
        let heard = Heard()
        EditWatcher.watch(element: nil, inserted: inserted, dictationID: id, store: store, app: app, report: { heard.all.append($0) })
        #expect(try one(heard.all).line == "learning app=com.brave.Browser result=unreadable at=start verdict=unknown coverage=fieldUnreadable looks=0 readable=0")
    }

    @Test("a field no look could read: unreadable at the first look, with how many looks were taken")
    func unreadableField() async throws {
        let line = try one(try await watch(store: try Store()) { _ in unreadable }).line
        #expect(line == "learning app=com.brave.Browser result=unreadable at=look-1 verdict=unknown coverage=fieldUnreadable looks=19 readable=0")
    }

    @Test("the gate's refusal is named, whether it is known at the paste or found by a look")
    func refusals() async throws {
        let excluded = try one(try await watch(store: try Store(), learning: false, refusal: .excludedApp, field: then(fixed)))
        // With nothing to learn only the verdict look is taken.
        #expect(excluded.line == "learning app=com.brave.Browser result=refused why=excluded-app verdict=kept coverage=observed looks=1 readable=1")
        let fixed = fixed, pasted = inserted
        let secure = try one(try await watch(store: try Store()) { look in
            look == 3 ? .init(fieldValue: nil, coverage: .secure) : .init(fieldValue: look <= 2 ? pasted : fixed, coverage: .observed)
        })
        #expect(secure.outcome == .refused(.secureField))
        let code = try one(try await watch(store: try Store(), context: LearningContext(appBundleID: app, isCodeContext: true), field: then(fixed)))
        #expect(code.outcome == .refused(.codeContext))
        let off = try one(try await watch(store: try Store(), isStillAllowed: { false }, field: then(fixed)))
        #expect(off.outcome == .notLearning(.switchedOff))
        let verdictOnly = try one(try await watch(store: try Store(), learning: false, field: then(fixed)))
        #expect(verdictOnly.outcome == .notLearning(.notAsked))
    }

    @Test("a watch that ends early says why: cancelled, or the dictation changed under it")
    func stopped() async throws {
        let cancelled = try one(try await watch(store: try Store(), sleep: { _ in throw CancellationError() }) { _ in unreadable })
        #expect(cancelled.line == "learning app=com.brave.Browser result=stopped why=cancelled looks=0 readable=0")
        let store = try Store()
        let superseded = try one(try await watch(store: store, sleep: { _ in try store.deleteAllDictations() }, field: then(fixed)))
        #expect(superseded.outcome == .stopped(.superseded))
        // Watched with no saved dictation behind it: there is no record to hold a verdict.
        let heard = Heard()
        await EditWatcher.observe(inserted: inserted, dictationID: 404, store: try Store(), app: app, report: { heard.all.append($0) },
                                  readField: { unreadable }, sleep: { _ in }).value
        #expect(try one(heard.all).outcome == .stopped(.noRecord))
    }

    @Test("a dictation left as it was: no change")
    func noChange() async throws {
        let line = try one(try await watch(store: try Store(), field: then(inserted))).line
        #expect(line == "learning app=com.brave.Browser result=no-change verdict=kept coverage=observed looks=19 readable=19")
    }

    @Test("a change that was seen and dropped names the rule")
    func dropped() async throws {
        let rewrite = try one(try await watch(store: try Store(), field: then(inserted.replacingOccurrences(of: "today", with: "tomorrow"))))
        #expect(rewrite.line == "learning app=com.brave.Browser result=dropped why=rewrite changes=1 verdict=edited coverage=observed looks=19 readable=19")
        let longer = inserted.replacingOccurrences(of: "report", with: "report and the two long overdue Nerula summaries")
        #expect(try one(try await watch(store: try Store(), field: then(longer))).outcome == .dropped(.shareChanged(percent: 58)))
        // Seen as pasted, then emptied or replaced: nothing was changed while it could be seen.
        #expect(try one(try await watch(store: try Store(), field: then(""))).outcome == .noChange)
        let other = "the crates are packed and the cart leaves at dawn"
        #expect(try one(try await watch(store: try Store(), field: then(other))).outcome == .noChange)
        #expect(try one(try await watch(store: try Store(), field: { _ in .init(fieldValue: other, coverage: .observed) })).outcome == .dropped(.notLocated))
        // Two words, both replaced: not the one shape a short dictation is learned from.
        let short = try one(try await watch("ask Velorya", store: try Store()) { look in
            .init(fieldValue: look <= 2 ? "ask Velorya" : "tell Veloria", coverage: .observed)
        })
        #expect(short.outcome == .dropped(.shortNoFix(words: 2)))
    }

    @Test("a fix is a candidate at one of two, in use at the second dictation, and only noted after that")
    func candidateThenLearned() async throws {
        let store = try Store()
        let first = try one(try await watch(store: store, field: then(fixed)))
        #expect(first.line == "learning app=com.brave.Browser result=candidate items=1 progress=1/2 verdict=edited coverage=observed looks=19 readable=19")
        let second = try one(try await watch(store: store, field: then(fixed)))
        #expect(second.outcome == .learned(items: 1))
        let third = try one(try await watch(store: store, field: then(fixed)))
        #expect(third.outcome == .alreadyLearned(items: 1))
        // Told to forget it, the same fix is understood and not written.
        let id = try #require(try store.learnedItems().first?.id)
        try store.forgetLearnedItem(id: id)
        let fourth = try one(try await watch(store: store, field: then(fixed)))
        #expect(fourth.outcome == .notRecorded(.forgotten))
    }

    @Test("no line carries a word of the dictation or of the field")
    func nothingSpokenOrTyped() async throws {
        let store = try Store()
        var lines: [String] = []
        for later in [fixed, inserted, "", inserted.replacingOccurrences(of: "today", with: "tomorrow"), "the crates are packed"] {
            lines += try await watch(store: store, field: then(later)).map(\.line)
        }
        #expect(lines.count == 5)
        let words = Set((inserted + " " + fixed + " tomorrow crates packed").lowercased().split(separator: " ").map(String.init))
        for line in lines {
            let tokens = line.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(words.isDisjoint(with: tokens), "\(line)")
        }
    }

    @Test("a dictation that is not watched says why")
    func notWatched() {
        #expect(EditWatcher.notWatched(isSaved: false, status: .inserted, pressesReturn: false) == .notSaved)
        #expect(EditWatcher.notWatched(isSaved: true, status: .notInserted, pressesReturn: false) == .notInserted)
        #expect(EditWatcher.notWatched(isSaved: true, status: .cancelled, pressesReturn: true) == .notInserted)
        #expect(EditWatcher.notWatched(isSaved: true, status: .inserted, pressesReturn: true) == .spokenReturn)
        #expect(EditWatcher.notWatched(isSaved: true, status: .inserted, pressesReturn: false) == nil)
    }
}
