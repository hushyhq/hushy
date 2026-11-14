import Foundation
import GRDB
import Testing
@testable import MurmurCore

private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let mail = "com.apple.mail", spark = "com.readdle.smartemail", slack = "com.tinyspeck.slackmacgap"

private func capture(_ id: Int64, _ before: String = "text", _ after: String = "Next", day offset: Double, app: String = mail) -> CorrectionCapture {
    CorrectionCapture(dictationID: id, appBundleID: app, capturedAt: start.addingTimeInterval(offset * day),
                      events: [CorrectionEvent(kind: .asrTerm, before: before, after: after)])
}

private func observe(_ item: LearnedItem?, _ capture: CorrectionCapture, policy: LearningPolicy = .standard,
                     backfill: ((LearnedItem) -> [EvidenceCell])? = nil) -> LearnedItem? {
    Learner.observe(capture, existing: item.map { [$0] } ?? [], knownTerms: [], policy: policy, backfill: backfill).first ?? item
}

private func expose(_ item: LearnedItem?, app: String = mail, day offset: Double, policy: LearningPolicy = .standard) -> LearnedItem? {
    item.map { Learner.expose($0, app: app, now: start.addingTimeInterval(offset * day), policy: policy) }
}

@Suite("Learning · evidence math")
struct EvidenceMathTests {
    @Test("with nothing left alone the sureness is 1 - 0.5^(1 + edits)")
    func closedForm() {
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 0, kept: 0) - 0.5) < 1e-9)
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 1, kept: 0) - 0.75) < 1e-9)
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 2, kept: 0) - 0.875) < 1e-9)
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 2.5, kept: 0) - (1 - pow(0.5, 3.5))) < 1e-9)
    }

    @Test("left-alone counts lower it; the Beta cases agree with the exact integrals")
    func withKept() {
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 2, kept: 1) - 0.6875) < 1e-9)
        #expect(abs(EvidenceMath.probabilityAboveHalf(edits: 3, kept: 1) - 0.8125) < 1e-9)
        #expect(EvidenceMath.probabilityAboveHalf(edits: 2, kept: 6) < 0.1)
    }

    @Test("counts halve every half-life and never grow when time goes backwards")
    func decay() {
        let cell = EvidenceCell(app: "a", edits: 4, kept: 2, updatedAt: start)
        let later = cell.decayed(to: start.addingTimeInterval(8 * day), halfLife: 8 * day)
        #expect(abs(later.edits - 2) < 1e-9 && abs(later.kept - 1) < 1e-9)
        #expect(cell.decayed(to: start.addingTimeInterval(-day), halfLife: 8 * day) == cell)
    }

    @Test("a scope is stored and read back")
    func scopeRoundTrip() {
        for scope in [LearnedScope.global, .category(.email), .app("com.apple.mail")] {
            #expect(LearnedScope(stored: scope.stored) == scope)
        }
        #expect(LearnedScope(stored: "nonsense") == nil)
    }
}

@Suite("Learning · evidence rule")
struct EvidenceRuleTests {
    @Test("with nothing left alone, two edits promote exactly where the earlier rule did: inside 14 days, not after")
    func sameAsEarlierRuleWithoutExposures() {
        for gap in [0.0, 1, 3, 7, 12, 13.5] {
            let now = observe(observe(nil, capture(1, day: 0)), capture(2, day: gap))
            let before = observe(observe(nil, capture(1, day: 0), policy: .editsOnly), capture(2, day: gap), policy: .editsOnly)
            #expect(now?.status == .active && before?.status == .active, "gap \(gap)")
        }
        for gap in [14.5, 15, 21, 30, 60] {
            let now = observe(observe(nil, capture(1, day: 0)), capture(2, day: gap))
            let before = observe(observe(nil, capture(1, day: 0), policy: .editsOnly), capture(2, day: gap), policy: .editsOnly)
            #expect(now?.status == .candidate && before?.status == .candidate, "gap \(gap)")
        }
    }

    @Test("one edit never promotes a whole-word term")
    func oneEditIsNotEnough() {
        let item = observe(nil, capture(1, "Karthik", "Priya", day: 0))
        #expect(item?.status == .candidate)
        #expect(item.map { $0.confidence < 1 } == true)
    }

    @Test("a word the person usually leaves alone is not learned from two edits")
    func exposuresBlock() {
        var item = observe(nil, capture(1, day: 0))
        for offset in stride(from: 0.5, through: 5.5, by: 1) { item = expose(item, day: offset) }
        item = observe(item, capture(2, day: 6))
        #expect(item?.status == .candidate)
        let earlier = observe(observe(nil, capture(1, day: 0), policy: .editsOnly), capture(2, day: 6), policy: .editsOnly)
        #expect(earlier?.status == .active)
    }

    @Test("a word is learned once the fixes outweigh the times it was left alone")
    func fixesCanOutweighExposures() {
        var item = observe(nil, capture(1, day: 0))
        item = expose(item, day: 0.2)
        item = observe(item, capture(2, day: 0.4))
        #expect(item?.status == .candidate)
        item = observe(item, capture(3, day: 0.6))
        #expect(item?.status == .active)
    }

    @Test("earlier History that left the word alone counts at the first fix")
    func backfillBlocksTheOneLetterShortcut() throws {
        let supported = try #require(CorrectionCapture.derive(
            inserted: "Please send Pria today.", raw: "Please send Pria today.", fieldValue: "Please send Priya today.",
            context: LearningContext(appBundleID: mail), dictationID: 1, now: start))
        #expect(observe(nil, supported)?.status == .active)
        let history: (LearnedItem) -> [EvidenceCell] = { _ in [EvidenceCell(app: mail, kept: 3, updatedAt: start)] }
        #expect(observe(nil, supported, backfill: history)?.status == .candidate)
    }

    @Test("the same dictation counts once, and counts are never negative")
    func sameDictation() {
        var item = observe(nil, capture(1, day: 0))
        item = observe(item, capture(1, day: 0))
        let cell = item?.evidence.first
        #expect(cell?.edits == 1 && (cell?.kept ?? -1) == 0)
    }

    @Test("an item written before the counts existed keeps working: its observation times stand in")
    func legacyItem() throws {
        var legacy = LearnedItem(kind: .term, key: "next", value: "Next", heardAs: ["text"], status: .active, observations: 2,
                                 sourceDictationIDs: [1, 2], observedAt: [start, start.addingTimeInterval(day)],
                                 createdAt: start, lastSeenAt: start, activatedAt: start, announced: true)
        #expect(legacy.evidence.isEmpty && legacy.scope == .global)
        // Leaving it alone later never takes it back: what was learned does not lapse.
        for offset in 1...40 { legacy = Learner.expose(legacy, app: slack, now: start.addingTimeInterval(Double(offset) * 10 * day)) }
        #expect(legacy.status == .active && legacy.scope == .global)
        // A new edit starts from the old observations, not from nothing.
        let item = try #require(observe(
            LearnedItem(kind: .term, key: "next", value: "Next", heardAs: ["text"], status: .candidate, observations: 1,
                        sourceDictationIDs: [1], observedAt: [start], createdAt: start, lastSeenAt: start),
            capture(2, day: 5)))
        #expect(item.status == .active)
    }

    @Test("forgetting drops the counts")
    func forgetClears() throws {
        let item = try #require(observe(nil, capture(1, day: 0)))
        #expect(!item.evidence.isEmpty)
        #expect(Learner.forget(item).evidence.isEmpty)
    }

    @Test("the earlier rule is still there behind the policy switch")
    func switchedOff() {
        var item = observe(nil, capture(1, day: 0), policy: .editsOnly)
        item = expose(item, day: 1, policy: .editsOnly)
        #expect(item?.evidence.isEmpty == true)
    }
}

@Suite("Learning · scope and backoff")
struct EvidenceScopeTests {
    @Test("a word fixed in Mail and left alone in Slack stays in Mail's kind of app")
    func narrowsToCategory() throws {
        var item = observe(nil, capture(1, day: 0))
        for offset in stride(from: 0.1, through: 0.6, by: 0.1) { item = expose(item, app: slack, day: offset) }
        item = observe(item, capture(2, day: 1))
        let learned = try #require(item)
        #expect(learned.status == .active)
        #expect(learned.scope == .category(.email))
        #expect(learned.applies(inApp: mail) && learned.applies(inApp: spark))
        #expect(!learned.applies(inApp: slack) && !learned.applies(inApp: nil))
    }

    @Test("fixes in Mail make the word global unless an app clearly leaves it alone (two times, none changed)")
    func contradictionBlocksGlobal() throws {
        func learned(slackLeftAlone: Int) throws -> LearnedItem {
            var item = observe(nil, capture(1, day: 0))
            for step in 0..<slackLeftAlone { item = expose(item, app: slack, day: 0.05 + Double(step) * 0.01) }
            for (index, offset) in [0.2, 0.4, 0.6, 0.8].enumerated() { item = observe(item, capture(Int64(2 + index), day: offset)) }
            return try #require(item)
        }
        #expect(try learned(slackLeftAlone: 1).scope == .global)
        #expect(try learned(slackLeftAlone: 2).scope == .category(.email))
    }

    @Test("with the same kind of app also leaving it alone, it stays with the one app")
    func narrowsToApp() throws {
        var item = observe(nil, capture(1, day: 0))
        for offset in stride(from: 0.1, through: 0.6, by: 0.1) { item = expose(item, app: spark, day: offset) }
        item = observe(item, capture(2, day: 1))
        let learned = try #require(item)
        #expect(learned.status == .active)
        #expect(learned.scope == .app(mail))
        #expect(learned.applies(inApp: mail) && !learned.applies(inApp: spark))
    }

    @Test("fixes in other apps widen it, and nothing ever narrows an active term")
    func widens() throws {
        var item = observe(nil, capture(1, day: 0))
        for offset in stride(from: 0.1, through: 0.6, by: 0.1) { item = expose(item, app: slack, day: offset) }
        item = observe(item, capture(2, day: 1))
        #expect(item?.scope == .category(.email))
        for (index, offset) in [2.0, 2.2, 2.4, 2.6, 2.8, 3.0, 3.2, 3.4].enumerated() {
            item = observe(item, capture(Int64(10 + index), day: offset, app: slack))
        }
        #expect(item?.scope == .global)
        let wide = try #require(item)
        let after = Learner.expose(wide, app: slack, now: start.addingTimeInterval(4 * day))
        #expect(after.scope == .global && after.status == .active)
    }

    @Test("terms scoped to some apps reach the dictionary only there")
    func personalizerScopes() throws {
        var item = observe(nil, capture(1, "Karthik", "Priya", day: 0))
        for offset in stride(from: 0.1, through: 0.6, by: 0.1) { item = expose(item, app: slack, day: offset) }
        item = observe(item, capture(2, "Karthik", "Priya", day: 1))
        let learned = try #require(item)
        #expect(learned.scope == .category(.email))
        let personalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: [learned])
        let text = "Send it to Karthik today."
        #expect(personalizer.scoped(to: mail).apply(text).text == "Send it to Priya today.")
        #expect(personalizer.scoped(to: spark).apply(text).text == "Send it to Priya today.")
        #expect(personalizer.scoped(to: slack).apply(text).text == text)
        #expect(personalizer.apply(text).text == text)
    }

    @Test("a global term still reaches every app, and the dictionary lists split cleanly")
    func globalStillGlobal() throws {
        let item = try #require(observe(observe(nil, capture(1, "Karthik", "Priya", day: 0)), capture(2, "Karthik", "Priya", day: 1)))
        #expect(item.scope == .global && item.isGlobal)
        let personalizer = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: [item])
        #expect(personalizer.scoped(to: slack).apply("Send it to Karthik.").text == "Send it to Priya.")
        #expect(LearnedPersonalization.dictionaryEntries(from: [item]).map(\.term) == ["Priya"])
        #expect(LearnedPersonalization.dictionaryEntries(from: [item], appBundleID: slack).isEmpty)
    }
}

@Suite("Learning · words left alone")
struct ExposureDerivationTests {
    private let watched = [WatchedTerm(itemKey: "next", heardKeys: ["text"])]

    @Test("an unchanged dictation that wrote the heard word counts it")
    func unchanged() {
        let inserted = "Please text me the notes."
        let field = "Hi\n\(inserted)"
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [field], watched: watched) == ["next"])
    }

    @Test("an edit elsewhere in the dictation still leaves the word alone")
    func editedElsewhere() {
        let inserted = "Please text me the notes before lunch."
        let field = "Please text me the notes after lunch."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [field], watched: watched) == ["next"])
    }

    @Test("changing the word, or a word the capture taught, counts nothing")
    func changed() {
        let inserted = "Please text me the notes before lunch."
        let fixed = "Please Next me the notes before lunch."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [fixed], watched: watched) == [])
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [inserted], watched: watched, editedKeys: ["next"]) == [])
    }

    @Test("a word Hushy did not hear (not in the raw text) or did not write counts nothing")
    func notWritten() {
        let inserted = "Please text me the notes."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: "Please send me the notes.", fieldValues: [inserted], watched: watched) == [])
        #expect(ExposureDerivation.leftAlone(inserted: "Please send me the notes.", raw: inserted, fieldValues: ["Please send me the notes."], watched: watched) == [])
    }

    @Test("when no read still holds the dictation nothing is known; an earlier read that does decides")
    func unknown() {
        let inserted = "Please text me the notes before lunch."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [""], watched: watched) == nil)
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: ["", "Something else entirely"], watched: watched) == nil)
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: ["", inserted], watched: watched) == ["next"])
    }

    @Test("two occurrences count only when both are left")
    func twoOccurrences() {
        let inserted = "Please text me, and text her the notes today."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [inserted], watched: watched) == ["next"])
        let one = "Please Next me, and text her the notes today."
        #expect(ExposureDerivation.leftAlone(inserted: inserted, raw: inserted, fieldValues: [one], watched: watched) == [])
    }
}

@Suite("Learning · evidence in the store")
struct EvidenceStoreTests {
    @Test("v25 migrates an existing v24 database: old rows read back with no counts and apply everywhere")
    func migrationFromV24() throws {
        let queue = try DatabaseQueue()
        try Store.migrator.migrate(queue, upTo: "v24-learned-term-review")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO learnedItem (kind, key, value, heardAs, status, observations, confirmed, confidence,
                                         sourceDictationIDs, observedAt, createdAt, lastSeenAt, announced)
                VALUES ('term', 'priya', 'Priya', '["Pria"]', 'active', 2, 0, 1, '[1,2]', '[]', ?, ?, 1)
                """, arguments: [start, start])
        }
        try Store.migrator.migrate(queue)
        let item = try #require(try queue.read { try LearnedItem.fetchOne($0) })
        #expect(item.value == "Priya" && item.status == .active)
        #expect(item.evidence.isEmpty && item.scope == .global && item.isGlobal)
    }

    @Test("counts persist with the item and leave only counts behind")
    func roundTrip() throws {
        let store = try Store()
        try store.recordCorrections(CorrectionCapture(dictationID: 1, appBundleID: mail, capturedAt: start,
                                                       events: [CorrectionEvent(kind: .asrTerm, before: "text", after: "Next")]))
        let item = try #require(try store.learnedItems().first)
        #expect(item.evidence == [EvidenceCell(app: mail, edits: 1, kept: 0, updatedAt: start)])
        let watched = try store.watchedTerms(app: mail)
        #expect(watched == [WatchedTerm(itemKey: "next", heardKeys: ["text"])])
        let changed = try store.recordLeftAlone(["next"], app: slack, dictationID: 2, at: start.addingTimeInterval(day))
        #expect(changed.count == 1)
        let after = try #require(try store.learnedItems().first)
        #expect(Set(after.evidence.map(\.app)) == [mail, slack])
        #expect(after.evidence.first { $0.app == slack }?.kept == 1)
    }

    @Test("a deleted or replaced dictation is not counted")
    func stale() throws {
        let store = try Store()
        try store.recordCorrections(CorrectionCapture(dictationID: 1, appBundleID: mail, capturedAt: start,
                                                       events: [CorrectionEvent(kind: .asrTerm, before: "text", after: "Next")]))
        let none = try store.recordLeftAlone(["next"], app: mail, dictationID: 99, at: start, expectedInsertedText: "never saved")
        #expect(none.isEmpty)
        #expect(try store.learnedItems().first?.evidence.first?.kept == 0)
    }

    @Test("History that left the word alone is counted once, as counts, when the word first becomes a candidate")
    func backfillFromHistory() throws {
        let store = try Store()
        for offset in 1...4 {
            let dictation = try store.save(Dictation(createdAt: start.addingTimeInterval(Double(-offset) * day), rawText: "text me the notes",
                                                     text: "Text me the notes.", appBundleID: slack, durationSeconds: 2))
            try store.setEditState(.kept, forDictation: try #require(dictation.id))
        }
        let edited = try store.save(Dictation(createdAt: start.addingTimeInterval(-5 * day), rawText: "text me", text: "Text me later.", durationSeconds: 2))
        try store.setEditState(.edited, forDictation: try #require(edited.id))
        try store.recordCorrections(CorrectionCapture(dictationID: 1, appBundleID: mail, capturedAt: start,
                                                       events: [CorrectionEvent(kind: .asrTerm, before: "text", after: "Next")]))
        let item = try #require(try store.learnedItems().first)
        let slackCell = try #require(item.evidence.first { $0.app == slack })
        #expect(slackCell.kept > 1.5 && slackCell.kept < 4)
        #expect(slackCell.edits == 0)
        #expect(item.evidence.first { $0.app == mail }?.edits == 1)
    }
}
