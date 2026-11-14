import Foundation
import MurmurCore

/// `murmur-eval learn-timelines [--trials N] [--seed S]`
///
/// The learning-timeline simulation of the 2026-10-26 algorithms audit (B10), rebuilt on the shipping `Learner`
/// (the first harness was a throwaway). A person says one word over 60 days; Hushy writes it as heard; each time the
/// person changes it or leaves it, with the chances of the scenario. Each timeline is run twice on the same events:
/// by the earlier rule (`LearningPolicy.editsOnly`: two edits in 14 days, nothing about words left alone) and by the
/// evidence rule (decayed counts of edits and times left alone, per app). Scenarios without a name for the person are
/// invented. The "History" the evidence rule reads when a word first becomes a candidate is the timeline's own earlier
/// left-alone dictations, exactly what `Store.earlierLeftAlone` reads from the real History.
enum LearnTimelines {
    static let days = 60
    static let heard = "text"
    static let written = "Next"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let mail = "com.apple.mail", spark = "com.readdle.smartemail", slack = "com.tinyspeck.slackmacgap"

    /// One place the word is said: how often a day, and how often the person changes what Hushy wrote.
    struct Stream {
        let app: String
        let perDay: Double
        let edit: Double
    }

    struct Scenario {
        let name: String
        let streams: [Stream]
        /// Only the first dictation is changed; every later one is left alone.
        var oneOff = false
        /// The app where the person does not want the swap (counts wrong applications), if any.
        var unwanted: String?
    }

    struct Result {
        var learned = 0
        var days: [Int] = []
        var wrongApplications = 0
        var timelinesWithWrongApplication = 0
        var scopes: [String: Int] = [:]
        var medianDay: Int? { days.sorted().isEmpty ? nil : days.sorted()[days.count / 2] }
    }

    /// The scenarios of the audit's B10, plus two apps where the person wants the swap in one and not in the other.
    static let scenarios: [Scenario] = [
        Scenario(name: "consistent fix, said often", streams: [Stream(app: mail, perDay: 0.35, edit: 1)]),
        Scenario(name: "consistent fix, said every 10 days", streams: [Stream(app: mail, perDay: 0.1, edit: 1)]),
        Scenario(name: "consistent fix, said every 25 days", streams: [Stream(app: mail, perDay: 0.04, edit: 1)]),
        Scenario(name: "ambiguous word, changed 1 time in 7", streams: [Stream(app: mail, perDay: 0.35, edit: 1.0 / 7)]),
        Scenario(name: "ambiguous word, changed 1 time in 4", streams: [Stream(app: mail, perDay: 0.35, edit: 0.25)]),
        Scenario(name: "one-off change", streams: [Stream(app: mail, perDay: 0.35, edit: 1)], oneOff: true),
        Scenario(name: "wanted in Mail, never in Slack", streams: [
            Stream(app: mail, perDay: 0.3, edit: 1), Stream(app: slack, perDay: 0.3, edit: 0)], unwanted: slack),
        Scenario(name: "wanted in Mail, never in Spark (same kind of app)", streams: [
            Stream(app: mail, perDay: 0.3, edit: 1), Stream(app: spark, perDay: 0.3, edit: 0)], unwanted: spark),
        Scenario(name: "wanted in both Mail and Slack", streams: [
            Stream(app: mail, perDay: 0.3, edit: 1), Stream(app: slack, perDay: 0.3, edit: 1)]),
    ]

    struct Event {
        let time: TimeInterval
        let app: String
        let edited: Bool
    }

    static func events(for scenario: Scenario, using rng: inout SeededGenerator) -> [Event] {
        var result: [Event] = []
        for day in 0..<days {
            for stream in scenario.streams where Double.random(in: 0..<1, using: &rng) < stream.perDay {
                let edited = Double.random(in: 0..<1, using: &rng) < stream.edit
                result.append(Event(time: (Double(day) + Double.random(in: 0..<1, using: &rng)) * 86_400, app: stream.app, edited: edited))
            }
        }
        result.sort { $0.time < $1.time }
        guard scenario.oneOff else { return result }
        return result.enumerated().map { Event(time: $1.time, app: $1.app, edited: $0 == 0) }
    }

    /// One timeline under one policy: the day the term became active (nil if it never did), where it applies at the
    /// end, and how many dictations in the unwanted app were swapped.
    private static func run(_ events: [Event], scenario: Scenario, policy: LearningPolicy) -> (day: Int?, scope: String?, wrong: Int) {
        var item: LearnedItem?
        var leftAlone: [(time: TimeInterval, app: String)] = []
        var day: Int?
        var wrong = 0
        for (index, event) in events.enumerated() {
            let now = base.addingTimeInterval(event.time)
            if let current = item, current.status == .active, current.applies(inApp: event.app), event.app == scenario.unwanted { wrong += 1 }
            if event.edited {
                let capture = CorrectionCapture(
                    dictationID: Int64(index + 1), appBundleID: event.app, capturedAt: now,
                    events: [CorrectionEvent(kind: .asrTerm, before: heard, after: written)])
                let earlier: (LearnedItem) -> [EvidenceCell] = { _ in
                    var byApp: [String: EvidenceCell] = [:]
                    for old in leftAlone where event.time - old.time <= policy.backfillWindow {
                        var cell = byApp[old.app] ?? EvidenceCell(app: old.app, updatedAt: now)
                        cell.kept += EvidenceMath.weight(afterSeconds: event.time - old.time, halfLife: policy.termHalfLife)
                        byApp[old.app] = cell
                    }
                    return Array(byApp.values)
                }
                if let changed = Learner.observe(capture, existing: item.map { [$0] } ?? [], knownTerms: [], policy: policy, backfill: earlier).first {
                    item = changed
                }
            } else {
                leftAlone.append((event.time, event.app))
                // A swap that is active where the person is dictating never shows its heard spelling: nothing to count.
                if let current = item, current.status != .forgotten, current.status == .candidate || !current.applies(inApp: event.app) {
                    item = Learner.expose(current, app: event.app, now: now, policy: policy)
                }
            }
            if day == nil, item?.status == .active { day = Int(event.time / 86_400) }
        }
        return (day, item?.status == .active ? item?.scope.stored : nil, wrong)
    }

    static func simulate(_ scenario: Scenario, policy: LearningPolicy, trials: Int, seed: UInt64) -> Result {
        var result = Result()
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<trials {
            let timeline = run(events(for: scenario, using: &rng), scenario: scenario, policy: policy)
            if let day = timeline.day {
                result.learned += 1
                result.days.append(day)
            }
            result.wrongApplications += timeline.wrong
            if timeline.wrong > 0 { result.timelinesWithWrongApplication += 1 }
            if let scope = timeline.scope { result.scopes[scope, default: 0] += 1 }
        }
        return result
    }

    static func run(_ args: Arguments) async throws {
        let trials = args.int("trials") ?? 2000
        let seed = UInt64(args.int("seed") ?? 7)
        print("### Learn timelines · \(trials) timelines of \(days) days per scenario (seed \(seed))\n")
        print("| Scenario | Earlier rule: learned (median day) | Evidence rule: learned (median day) | Wrong swaps per timeline: earlier → evidence | Where the evidence rule applies it |")
        print("|---|---|---|---|---|")
        for scenario in scenarios {
            let earlier = simulate(scenario, policy: .editsOnly, trials: trials, seed: seed)
            let evidence = simulate(scenario, policy: .standard, trials: trials, seed: seed)
            func cell(_ r: Result) -> String {
                "\(pct(Double(r.learned) / Double(trials))) (\(r.medianDay.map { "day \($0)" } ?? "—"))"
            }
            let wrong = scenario.unwanted == nil ? "—"
                : String(format: "%.2f → %.2f (%d%% → %d%% of timelines)", Double(earlier.wrongApplications) / Double(trials), Double(evidence.wrongApplications) / Double(trials),
                         earlier.timelinesWithWrongApplication * 100 / trials, evidence.timelinesWithWrongApplication * 100 / trials)
            let scopes = evidence.scopes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value * 100 / max(1, evidence.learned))%" }.joined(separator: ", ")
            print("| \(scenario.name) | \(cell(earlier)) | \(cell(evidence)) | \(wrong) | \(scopes.isEmpty ? "—" : scopes) |")
        }
    }

    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
