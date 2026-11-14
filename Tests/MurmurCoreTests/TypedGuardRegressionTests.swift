import Foundation
import Testing
@testable import MurmurCore

@Suite("Typed values and restarted guards")
struct TypedGuardRegressionTests {
    private func previousVerdict(_ draft: String, _ answer: String) -> SmartCleaner.Refinement {
        let verdict = OutputGuard.checkAgainst(draft, answer, raw: draft, lowConfidenceWords: nil,
                                               profile: .grammarRepair, knownWords: BoostGuard.systemWords)
        guard case .rejected(let reason) = verdict, RestartedFrame.relaxable.contains(GuardCode(reason: reason)),
              let shorter = RestartedFrame.withoutEarlierCopies(draft),
              CorrectionBound.violation(answer: answer, draft: draft) == nil,
              !RestartedFrame.addsAStance(answer: answer, draft: draft) else { return verdict }
        let retried = OutputGuard.checkAgainst(shorter, answer, raw: draft, lowConfidenceWords: nil,
                                               profile: .grammarRepair, knownWords: BoostGuard.systemWords)
        if case .accepted = retried { return retried }
        return verdict
    }

    private func accepts(_ draft: String, _ answer: String) -> Bool {
        OutputGuard.check(answer, raw: draft, draft: draft, profile: .grammarRepair) == .accepted(answer)
    }

    private func refuses(_ draft: String, _ answer: String) -> Bool {
        if case .rejected = OutputGuard.check(answer, raw: draft, draft: draft, profile: .grammarRepair) { return true }
        return false
    }

    @Test("ordinary typed spellings retain the verdict without the new gate and retries", arguments: [
        ("we grew 50 percent this year", "We grew 50% this year."),
        ("the covid 19 policy changed", "The COVID-19 policy changed."),
        ("meet at 3 pm tomorrow", "Meet at 3pm tomorrow."),
        ("ship the 5 k package", "Ship the 5k package."),
        ("the cost is $ 5", "The cost is $5."),
        ("we served 1,000 customers", "We served 1000 customers."),
        ("review Q 3 results", "Review Q3 results."),
        ("use iPhone 15", "Use iPhone 15."),
        ("install version 2.3", "Install version 2.3."),
        ("the rate is 2.5 percent", "The rate is 2.5%."),
        ("examples e.g. dogs", "Examples e.g. dogs."),
    ])
    func ordinarySpellings(draft: String, answer: String) {
        for profile: OutputGuard.Profile in [.disfluencyOnly, .grammarRepair] {
            let before = OutputGuard.checkAgainst(draft, answer, raw: draft, lowConfidenceWords: nil,
                                                  profile: profile, knownWords: BoostGuard.systemWords)
            let after = OutputGuard.check(answer, raw: draft, draft: draft, profile: profile)
            let oldAccepted: Bool = { if case .accepted = before { return true }; return false }()
            let newAccepted: Bool = { if case .accepted = after { return true }; return false }()
            #expect(newAccepted == oldAccepted, "\(profile): \(draft) → \(answer); before \(before), after \(after)")
        }
    }

    @Test("joined technical spelling keeps the old polished verdict")
    func joinedTechnicalSpelling() {
        let draft = "can you open auth dot swift and call parse header for me"
        let answer = "Can you open auth.swift and call parse_header for me?"
        #expect(OutputGuard.checkAgainst(draft, answer, raw: draft, lowConfidenceWords: nil,
                                         profile: .grammarRepair, knownWords: BoostGuard.systemWords) == .accepted(answer))
        #expect(accepts(draft, answer))
    }

    @Test("typed slots use the existing grammatical classes", arguments: [
        ("The demo is by three twenty no wait three forty.", "The demo is by 3:40."),
        ("The demo is before three twenty no wait three forty.", "The demo is before 3:40."),
        ("Start on your fourteenth visit.", "Start on your 14th visit."),
        ("Use Q two for this rollout.", "Use Q2 for this rollout."),
    ])
    func classBasedTypedSlot(draft: String, answer: String) {
        #expect(accepts(draft, answer))
    }

    @Test("clock retraction remains bound after another time cue")
    func clockRetractionWithOtherCue() {
        let draft = "The demo is by three twenty no wait three forty."
        #expect(refuses(draft, "The demo is by 3:20."))
    }

    @Test("an expanded copy cannot erase a separate fact", arguments: [
        ("The two roles the two supervisor roles are not open.", "The two supervisor roles are not open.", true),
        ("The two roles the two supervisor roles are open at three.", "The two supervisor roles are open at three.", false),
        ("The two roles the two supervisor roles for Maya are open.", "The two supervisor roles for Maya are open.", false),
        ("The two roles the two supervisor roles might be open.", "The two supervisor roles might be open.", false),
        ("The two roles, the two supervisor roles are open.", "The two supervisor roles are open.", false),
        ("The two roles and the two supervisor roles are open.", "The two supervisor roles are open.", false),
    ])
    func expandedSeparateFact(draft: String, answer: String, baselineAccepts: Bool) {
        #expect(RestartedFrame.withoutEarlierCopies(draft) == nil)
        let before = OutputGuard.checkAgainst(draft, answer, raw: draft, lowConfidenceWords: nil,
                                              profile: .grammarRepair, knownWords: BoostGuard.systemWords)
        let oldAccepted: Bool = { if case .accepted = before { return true }; return false }()
        #expect(oldAccepted == baselineAccepts)
        if !baselineAccepts { #expect(refuses(draft, answer)) }
    }

    @Test("a following clause about another thing at the corrected time remains")
    func correctedTimeSeparateFact() {
        let draft = "The demo is at three twenty no wait three forty the meeting is three forty."
        let answer = "The demo is at 3:40."
        #expect(CanonicalTypedGuard.resolvedClockDraft(draft, answer: answer)?.contains("the meeting is three forty") == true)
        #expect(refuses(draft, answer))
        let negated = "The demo is at three twenty no wait three forty it is not three forty."
        #expect(CanonicalTypedGuard.resolvedClockDraft(negated, answer: answer)?.contains("it is not three forty") == true)
        // The older correction path can itself accept a dropped negation. This retry must
        // preserve the clause and may not silently widen that existing verdict.
        let before = OutputGuard.checkAgainst(negated, answer, raw: negated, lowConfidenceWords: nil,
                                              profile: .grammarRepair, knownWords: BoostGuard.systemWords)
        if case .rejected = before { #expect(refuses(negated, answer)) }
    }

    @Test("spoken values may be typed exactly", arguments: [
        ("Start on the fourteenth.", "Start on the 14th."),
        ("Meet at two thirty tomorrow.", "Meet at 2:30 tomorrow."),
        ("Use v two for this rollout.", "Use v2 for this rollout."),
        ("Open cache underscore store dot py.", "Open cache_store.py."),
        ("Stop on motor underscore pid dot c.", "Stop on motor_pid.c."),
        ("Meet before seven today.", "Meet before 7 today."),
        ("The contract deadline is March twelfth the contract deadline is March fourteenth.",
         "The contract deadline is March 14th."),
    ])
    func exactTypedValue(draft: String, answer: String) {
        #expect(accepts(draft, answer))
    }

    @Test("different or unspoken typed values stay refused", arguments: [
        ("Start on the fourteenth.", "Start on the 15th."),
        ("Meet at two thirty tomorrow.", "Meet at 2:13 tomorrow."),
        ("Use v two for this rollout.", "Use v3 for this rollout."),
        ("Open cache underscore store dot py.", "Open cache_stores.py."),
        ("Stop on motor underscore pid dot c.", "Stop on motor_pids.c."),
        ("Meet before seven today.", "Meet before 8 today."),
        ("The matinee call is at three the matinee call is at two thirty and evenings are seven.",
         "The matinee call is at 3:30 and evenings are at 7."),
        ("The contract deadline is March twelfth the contract deadline is March fourteenth.",
         "The contract deadline is March 13th."),
        ("Send the summary to legal.", "Send the 2nd summary to legal."),
        ("Ship the report now.", "Ship report #2 now."),
        ("Review the draft soon.", "Review the 2x draft soon."),
        ("Increase the budget.", "Increase the budget 2%."),
        ("Send the report tomorrow.", "Send the report at 2pm tomorrow."),
        ("Put it on the desk.", "Put it on desk2."),
        ("Reduce the amount.", "Reduce the amount by -2."),
        ("Open alpha_store.py then close beta_store.py.", "Open beta_store.py then close alpha_store.py."),
        ("Meet at two thirty tomorrow and call at three forty Friday.",
         "Meet at 3:40 tomorrow and call at 2:30 Friday."),
    ])
    func wrongTypedValue(draft: String, answer: String) {
        #expect(refuses(draft, answer))
    }

    @Test("ordinary one-letter words cannot license joined digits", arguments: [
        ("Please play a two.", "Please play A2."),
        ("Please play I two.", "Please play I2."),
    ])
    func ordinaryOneLetterWord(draft: String, answer: String) {
        for profile: OutputGuard.Profile in [.disfluencyOnly, .grammarRepair] {
            let verdict = OutputGuard.check(answer, raw: draft, draft: draft, profile: profile)
            guard case .rejected = verdict else {
                Issue.record("\(profile): \(draft) → \(answer); got \(verdict)")
                continue
            }
        }
    }

    @Test("spoken consonant letters can license joined digits", arguments: [
        ("Use v two for this rollout.", "Use v2 for this rollout."),
        ("Use Q two for this rollout.", "Use Q2 for this rollout."),
    ])
    func consonantLetterDigit(draft: String, answer: String) {
        #expect(accepts(draft, answer))
    }

    @Test("an exact duplicate within a restarted frame may go", arguments: [
        ("We can't we can't keep up.", "We can't keep up."),
        ("The two roles the two roles are open.", "The two roles are open."),
        ("Not yet, not yet.", "Not yet."),
        ("The back unit can't you know it can't keep up.", "The back unit can't keep up."),
        ("The two roles the two supervisor roles are open.", "The two supervisor roles are open."),
        ("So the episode is recorded so the episode is finally recorded.", "The episode is finally recorded."),
    ])
    func restartedDuplicate(draft: String, answer: String) {
        #expect(accepts(draft, answer))
    }

    @Test("a repeat with intervening content remains unproved", arguments: [
        ("Don't escalate it it's not there yet don't escalate.", "Don't escalate it. It's not there yet."),
    ])
    func unprovedDuplicate(draft: String, answer: String) {
        #expect(refuses(draft, answer))
    }

    @Test("a connective, changed slot or different content is not a duplicate", arguments: [
        ("We should not ship and we should never ship.", "We should never ship."),
        ("Charge 12 dollars and charge 12 dollars.", "Charge 12 dollars."),
        ("Not yet and not yet.", "Not yet."),
        ("The two roles then the two supervisor roles are open.", "The two supervisor roles are open."),
        ("The two roles the three supervisor roles are open.", "The three supervisor roles are open."),
        ("The back unit can't and it can't keep up.", "The back unit can't keep up."),
        ("The two roles and the two supervisor roles are open.", "The two supervisor roles are open."),
        ("The two roles the two supervisor jobs are open.", "The two supervisor jobs are open."),
    ])
    func separateStatements(draft: String, answer: String) {
        #expect(refuses(draft, answer))
    }

    @Test("the final clock value of a cued correction may be typed")
    func finalCorrectedTime() {
        let draft = "The demo is at three twenty no wait three forty it was three forty."
        let answer = "The demo is at 3:40."
        #expect(accepts(draft, answer), "\(OutputGuard.check(answer, raw: draft, draft: draft, profile: .grammarRepair)); canonical: \(CanonicalTypedGuard.canonicalDraft(draft))")
    }

    @Test("the retracted or invented clock value may not replace the final one", arguments: [
        ("The demo is at two fifteen no sorry two forty five.", "The demo is at 2:15."),
        ("The demo is at two fifteen no sorry two forty five.", "The demo is at 2:35."),
        ("The show starts at four twenty no wait four fifty.", "The show starts at 4:20."),
    ])
    func wrongCorrectedTime(draft: String, answer: String) {
        #expect(refuses(draft, answer))
    }

    @Test("keeping both clock values with the cue is not a retracted-value error")
    func keepsBothCorrectedValues() {
        let draft = "The demo is at two fifteen no sorry two forty five."
        let answer = "The demo is at 2:15, no sorry, 2:45."
        #expect(CanonicalTypedGuard.violation(answer: answer, draft: draft) == nil)
        #expect(CorrectionBound.violation(answer: answer, draft: draft) == nil)
    }

    @Test("an ambiguous correction still uses the existing value bound")
    func ambiguousCorrection() {
        let draft = "The fee is five dollars and fifty cents no wait six dollars and fifty cents."
        #expect(CorrectionBound.violation(answer: "The fee is $5.50.", draft: draft) == nil)
        #expect(CorrectionBound.violation(answer: "The fee is $5.75.", draft: draft) == "changed digits")
    }

    @Test("training pair check uses the same typed value bound")
    func trainingPairTypedValue() {
        let raw = "Start on the fourteenth."
        #expect(TrainingPairCheck.check(raw: raw, target: "Start on the 14th.", level: .polished).rejection == nil)
        #expect(TrainingPairCheck.check(raw: raw, target: "Start on the 15th.", level: .polished).rejection != nil)
    }

    @Test("the retrain pair corpus keeps every previous acceptance", .enabled(if: PrivateFiles.present("Evals/runs/retrain/v4-refused-group-pairs.jsonl"), "needs a private file: Evals/runs/retrain/v4-refused-group-pairs.jsonl"))
    func retrainPairs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Evals/runs/retrain/v4-refused-group-pairs.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return } // Local, git-ignored audit corpus.
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        var newlyAccepted: [Int] = []
        var stillRefused: [(Int, String)] = []
        var recordedMismatch: [Int] = []
        var currentMismatch: [Int] = []
        var changedPreviousAcceptance: [Int] = []
        for (index, line) in lines.enumerated() {
            let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let draft = try #require(row["draft"] as? String)
            let target = try #require(row["target"] as? String)
            let wasRefused = row["rejection"] is String
            let verdict = OutputGuard.check(target, raw: draft, draft: draft, profile: .grammarRepair)
            let previous = previousVerdict(draft, target)
            if !wasRefused, case .rejected = previous { recordedMismatch.append(index) }
            if !wasRefused, case .rejected = verdict { currentMismatch.append(index) }
            if case .accepted = previous, case .rejected = verdict { changedPreviousAcceptance.append(index) }
            switch verdict {
            case .accepted:
                if wasRefused { newlyAccepted.append(index) }
            case .rejected(let reason):
                if wasRefused { stillRefused.append((index, reason)) }
            }
        }
        print("retrain newly accepted: \(newlyAccepted)")
        print("retrain still refused: \(stillRefused)")
        print("retrain recorded/direct baseline mismatch: \(recordedMismatch)")
        print("retrain recorded/direct current mismatch: \(currentMismatch)")
        print("retrain previous direct acceptances now refused: \(changedPreviousAcceptance)")
        #expect(lines.count == 302)
        #expect(recordedMismatch == [181])
        #expect(currentMismatch == recordedMismatch)
        #expect(changedPreviousAcceptance.isEmpty)
    }
}
