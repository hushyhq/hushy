import Foundation
import Testing
@testable import MurmurCore

/// The frozen replay set for learning from edits (`Fixtures/learning-replay.jsonl`, written by
/// `scripts/learning_replay_gen.py`; every session is invented). Each session's field timeline is
/// read at the app's own schedule (`LearningReadSchedule`, plus the Return read), run through
/// `CorrectionCapture.explainLatest` and `Learner`, and scored against what the person meant.
///
/// `LEARNING_REPLAY_OUT=<file>` also writes the metrics line and every miss there.
@Suite("Learning · replay set")
struct LearningReplayTests {
    struct Session: Decodable {
        let id: String
        let app: String
        let codeContext: Bool
        let inserted: String
        let raw: String
        let timeline: [State]
        let expect: [String]
        let located: Bool
        let day: Double
        var swaps: [Swap]? = nil
        var returnAt: Double? = nil
        var history: String? = nil
        var activeAfter: [String]? = nil
        var unedited: Bool? = nil
        /// False for a field that never reports a change (no change reads); reported by default.
        var postsChanges: Bool? = nil
        /// How long after `returnAt` the Return read sees the field (an app that empties it while handling the key).
        var returnReadLag: Double? = nil

        struct Swap: Decodable { let heard: String; let written: String }

        /// `[seconds after the paste, field text or null]`.
        struct State: Decodable {
            let at: Double
            let value: String?
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                at = try container.decode(Double.self)
                value = try container.decodeNil() ? nil : try container.decode(String.self)
            }
        }

        func value(at time: Double) -> String? {
            timeline.last { $0.at <= time }?.value
        }
    }

    /// How the replay reads a session; the controls change only this. A change read lands `changeLag` after each change
    /// in the session's timeline (`LiveEditWatch.readOnChange`), when the field reports changes.
    struct Reader {
        var offsets: [TimeInterval] = LearningReadSchedule.offsets
        var usesReturnRead = true
        var usesChangeReads = true
        var changeLag: TimeInterval = 0.02
        var isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord

        func reads(_ session: Session) -> [FieldRead] {
            var reads = offsets.map { FieldRead(value: session.value(at: $0), security: .notSecure, elapsed: $0) }
            if usesReturnRead, let pressed = session.returnAt, pressed <= LearningReadSchedule.lastOffset {
                let at = pressed + (session.returnReadLag ?? 0)
                reads.append(FieldRead(value: session.value(at: at), security: .notSecure, elapsed: at, onReturn: true))
            }
            if usesChangeReads, session.postsChanges != false {
                let changes = session.timeline.map(\.at).filter { $0 > 0 && $0 + changeLag <= LearningReadSchedule.lastOffset }
                reads += changes.prefix(LearningReadSchedule.maxChangeReads).map {
                    FieldRead(value: session.value(at: $0 + changeLag), security: .notSecure, elapsed: $0 + changeLag, onChange: true)
                }
            }
            return reads.sorted { $0.elapsed < $1.elapsed }
        }

        func snapshots(_ session: Session) -> [FieldSnapshot] {
            LearningReads.resolve(reads(session)).snapshots
        }
    }

    struct Score: CustomStringConvertible {
        var sessions = 0, locatable = 0, located = 0
        var truePositive = 0, falsePositive = 0, falseNegative = 0
        var activeTrue = 0, activeFalse = 0, activeMissed = 0
        var unedited = 0, mislabelled = 0
        var misses: [String] = []

        var locatedShare: Double { Double(located) / Double(max(locatable, 1)) }
        var precision: Double { Double(truePositive) / Double(max(truePositive + falsePositive, 1)) }
        var recall: Double { Double(truePositive) / Double(max(truePositive + falseNegative, 1)) }

        var description: String {
            func pct(_ value: Double) -> String { String(format: "%.1f", value * 100) }
            return "sessions=\(sessions) located=\(located)/\(locatable) (\(pct(locatedShare))%) "
                + "lessons tp=\(truePositive) fp=\(falsePositive) fn=\(falseNegative) "
                + "precision=\(pct(precision))% recall=\(pct(recall))% harmful=\(falsePositive) "
                + "active tp=\(activeTrue) fp=\(activeFalse) fn=\(activeMissed) "
                + "mislabelled=\(mislabelled)/\(unedited)"
        }
    }

    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func load(_ name: String = "learning-replay.jsonl") throws -> [Session] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Session.self, from: Data($0.utf8))
        }
    }

    static func lessons(_ capture: CorrectionCapture) -> Set<String> {
        let observed = Learner.observations(from: capture).map { observation in
            observation.kind == .term ? "term:\(observation.key)" : "style:\(observation.key)"
        }
        return Set(observed + capture.reverts.map { "revert:\($0.swap.writtenKey)" })
    }

    static func name(_ item: LearnedItem) -> String {
        item.kind == .term ? "term:\(item.key)" : "style:\(item.key)"
    }

    static func score(_ sessions: [Session], reader: Reader = Reader()) -> Score {
        var score = Score()
        var histories: [String: [LearnedItem]] = [:]
        for (index, session) in sessions.enumerated() {
            score.sessions += 1
            let context = LearningContext(appBundleID: session.app, isCodeContext: session.codeContext, elapsed: 0)
            let now = base.addingTimeInterval(session.day * 86_400)
            let swaps = (session.swaps ?? []).map { VocabularySwap(heard: $0.heard, written: $0.written, source: .dictionaryAlias) }
            let derivation: CorrectionDerivation = LearningGate.refusal(context).map { CorrectionDerivation.dropped(.refused($0)) }
                ?? CorrectionCapture.explainLatest(
                    inserted: session.inserted, raw: session.raw, snapshots: reader.snapshots(session), context: context,
                    dictationID: Int64(index + 1), now: now, swaps: swaps, isCommonWord: reader.isCommonWord)
            let got = derivation.capture.map(lessons) ?? []
            let want = Set(session.expect)
            score.truePositive += got.intersection(want).count
            score.falsePositive += got.subtracting(want).count
            score.falseNegative += want.subtracting(got).count
            if session.located {
                score.locatable += 1
                switch derivation {
                case .dropped(.notLocated), .dropped(.cleared), .dropped(.unreadable), .dropped(.unchanged): break
                default: score.located += 1
                }
                if case .dropped(let drop) = derivation, [.notLocated, .cleared, .unreadable, .unchanged].contains(drop) {
                    score.misses.append("\(session.id) not located why=\(drop)")
                }
            }
            if session.unedited == true {
                score.unedited += 1
                if derivation != .dropped(.unchanged) { score.mislabelled += 1 }
            }
            if got != want {
                score.misses.append("\(session.id) want=\(want.sorted()) got=\(got.sorted()) why=\(derivation.capture == nil ? "\(derivation)" : "capture")")
            }
            if let history = session.history {
                var items = histories[history] ?? []
                if let capture = derivation.capture {
                    let changed = Learner.observe(capture, existing: items, knownTerms: [], policy: .standard)
                    for item in changed {
                        if let at = items.firstIndex(where: { $0.identity == item.identity }) { items[at] = item } else { items.append(item) }
                    }
                }
                histories[history] = items
                if let expected = session.activeAfter.map(Set.init) {
                    let active = Set(items.filter { $0.status == .active || $0.isReadySuggestion }.map(name))
                    score.activeTrue += active.intersection(expected).count
                    score.activeFalse += active.subtracting(expected).count
                    score.activeMissed += expected.subtracting(active).count
                    if active != expected { score.misses.append("\(session.id) active want=\(expected.sorted()) got=\(active.sorted())") }
                }
            }
        }
        return score
    }

    @Test("the replay set scores, and both seeded controls score worse")
    func replay() throws {
        let sessions = try Self.load()
        #expect(sessions.count >= 80)
        let score = Self.score(sessions)
        let again = Self.score(sessions)
        // Controls: one hides the early reads (a locator that sees less), one calls every word a term (a classifier
        // that learns rewrites). Each must score worse on the metric it targets, or the set cannot tell.
        let scheduleOnly = Self.score(sessions, reader: Reader(usesChangeReads: false))
        let lateOnly = Self.score(sessions, reader: Reader(offsets: LearningReadSchedule.offsets.filter { $0 >= LearningReadSchedule.verdictOffset }, usesReturnRead: false, usesChangeReads: false))
        let everythingATerm = Self.score(sessions, reader: Reader(isCommonWord: { _ in false }))
        let report = (["replay \(score)", "repeat \(again)", "without-change-reads \(scheduleOnly)", "control-late-reads \(lateOnly)", "control-every-word-a-term \(everythingATerm)"]
            + score.misses.map { "miss \($0)" }).joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["LEARNING_REPLAY_OUT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        #expect(again.description == score.description, "the replay is deterministic")
        #expect(lateOnly.located < score.located, "a locator that sees fewer reads locates less")
        #expect(everythingATerm.falsePositive > score.falsePositive, "a classifier that learns rewrites is caught")
        // Floors from the hillclimb of 2026-11-04 (baseline: located 69/75, 58 lessons, 13 harmful, 3 wrong in use).
        #expect(score.falsePositive == 0, "no lesson the person did not mean")
        #expect(score.activeFalse == 0, "nothing in use that the person did not mean")
        #expect(score.located >= 75, "every edited dictation that was on screen is located")
        // Change reads (2026-11-11, fix/learn-edits-chat): 58 -> 64 lessons, active 3 -> 4, still none harmful.
        #expect(score.truePositive >= 64, "lessons learned")
        #expect(scheduleOnly.truePositive < score.truePositive, "change reads see fixes the schedule alone misses")
        #expect(score.mislabelled == 0, "a dictation left as it was says unchanged")
    }
}
