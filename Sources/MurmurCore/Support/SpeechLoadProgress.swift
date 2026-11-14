import Foundation

/// The stages the speech model goes through between launch and "ready", as the engine reports
/// them. Each is something that really happens; nothing here is a fraction of anything.
public enum SpeechLoadStage: String, Sendable, Codable, CaseIterable {
    /// The model's files are checked against their published checksums. Only on the launch after a
    /// download whose check could not finish; most launches never enter it.
    case checking
    /// Core ML loads the model's parts into memory. The long one, and far longer on the first
    /// launch after an update.
    case loading
    /// The model is in memory; a second of silence is run through it so the first real dictation
    /// is as fast as the rest.
    case warming

    /// What is happening, in a few plain words. The pill's row and the menu bar say this too.
    public var line: String {
        switch self {
        case .checking: "Checking the speech model"
        case .loading: "Loading the speech model"
        case .warming: "Warming up the speech model"
        }
    }

    /// The same in a sentence, for Home's card.
    public var sentence: String {
        switch self {
        case .checking: "Hushy is checking the speech model's files."
        case .loading: "Hushy is loading the speech model into memory."
        case .warming: "Hushy is warming up the speech model."
        }
    }
}

/// How long each stage took on this Mac on earlier launches. The first launch of a build is kept
/// apart from the rest: it is the slow one (Core ML prepares the model again), and mixing the two
/// would make every estimate wrong for both.
public struct SpeechLoadTimes: Sendable, Equatable, Codable {
    public struct Record: Sendable, Equatable, Codable {
        public var build: String
        public var firstOfBuild: Bool
        /// Seconds per stage, by `SpeechLoadStage.rawValue`.
        public var stages: [String: Double]

        public init(build: String, firstOfBuild: Bool, stages: [String: Double]) {
            self.build = build
            self.firstOfBuild = firstOfBuild
            self.stages = stages
        }
    }

    /// Records kept; older ones go.
    public static let limit = 12
    /// The fewest records of a kind before their middle value is called "usual".
    public static let fewest = 1

    public private(set) var records: [Record] = []

    public init(records: [Record] = []) {
        self.records = Array(records.suffix(Self.limit))
    }

    /// Whether `build` has never finished loading on this Mac.
    public func isFirstLaunch(of build: String) -> Bool {
        !records.contains { $0.build == build }
    }

    /// The middle duration of each stage over earlier launches of the same kind, or nil when
    /// there are none to go by. A stage no earlier launch went through has no entry.
    public func usual(firstOfBuild: Bool) -> [SpeechLoadStage: TimeInterval]? {
        let alike = records.filter { $0.firstOfBuild == firstOfBuild }
        guard alike.count >= Self.fewest else { return nil }
        var usual: [SpeechLoadStage: TimeInterval] = [:]
        for stage in SpeechLoadStage.allCases {
            let seconds = alike.compactMap { $0.stages[stage.rawValue] }.filter { $0 > 0 }.sorted()
            guard !seconds.isEmpty else { continue }
            usual[stage] = seconds[seconds.count / 2]
        }
        return usual.isEmpty ? nil : usual
    }

    public mutating func add(_ record: Record) {
        guard !record.stages.isEmpty else { return }
        records = Array((records + [record]).suffix(Self.limit))
    }
}

/// One load of the speech model, as far as it has got. Pure: `display(at:)` says what to show
/// at a moment, and a test moves the moment.
public struct SpeechLoadProgress: Sendable, Equatable {
    public private(set) var stage: SpeechLoadStage
    public let startedAt: Date
    public private(set) var stageStartedAt: Date
    /// The stages this load has finished, in order, with how long each really took.
    public private(set) var finished: [(stage: SpeechLoadStage, seconds: TimeInterval)] = []
    /// Model parts Core ML has started on in the loading stage, as the engine reports them.
    public private(set) var partsStarted = 0
    /// What each stage usually takes on this Mac for a launch like this one, when known.
    public let usual: [SpeechLoadStage: TimeInterval]?
    /// This build has not finished loading on this Mac before.
    public let isFirstLaunchOfBuild: Bool

    public init(stage: SpeechLoadStage = .loading, startedAt: Date, usual: [SpeechLoadStage: TimeInterval]? = nil,
                isFirstLaunchOfBuild: Bool = false) {
        self.stage = stage
        self.startedAt = startedAt
        stageStartedAt = startedAt
        self.usual = usual
        self.isFirstLaunchOfBuild = isFirstLaunchOfBuild
    }

    public static func == (a: SpeechLoadProgress, b: SpeechLoadProgress) -> Bool {
        a.stage == b.stage && a.startedAt == b.startedAt && a.stageStartedAt == b.stageStartedAt
            && a.partsStarted == b.partsStarted && a.usual == b.usual && a.isFirstLaunchOfBuild == b.isFirstLaunchOfBuild
            && a.finished.map(\.stage) == b.finished.map(\.stage) && a.finished.map(\.seconds) == b.finished.map(\.seconds)
    }

    /// The engine moved on. Stages only go forward; a report of the current or an earlier stage
    /// changes nothing.
    public mutating func enter(_ next: SpeechLoadStage, at now: Date) {
        guard Self.order(next) > Self.order(stage) else { return }
        finished.append((stage, max(0, now.timeIntervalSince(stageStartedAt))))
        stage = next
        stageStartedAt = now
    }

    /// Core ML started on another part of the model.
    public mutating func partStarted() {
        if stage == .loading { partsStarted += 1 }
    }

    /// Every stage this load went through with its real duration, the current one ending at `now`:
    /// what is remembered for next time once the model is ready.
    public func durations(endingAt now: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        for done in finished { result[done.stage.rawValue] = done.seconds }
        result[stage.rawValue] = max(0, now.timeIntervalSince(stageStartedAt))
        return result
    }

    private static func order(_ stage: SpeechLoadStage) -> Int {
        SpeechLoadStage.allCases.firstIndex(of: stage) ?? 0
    }

    // MARK: What to show

    public struct Display: Sendable, Equatable {
        public enum Step: Sendable, Equatable {
            case done
            /// Under way. `fraction` is how far through its usual time it is, or nil when there is
            /// no usual time to go by or it has run past it: then it is shown as in progress.
            case current(fraction: Double?)
            case pending
        }

        public struct Segment: Sendable, Equatable {
            public let stage: SpeechLoadStage
            public let step: Step
            /// The segment's share of the track's width.
            public let weight: Double
        }

        public let segments: [Segment]
        /// "Loading the speech model".
        public let line: String
        /// The sentence for the card.
        public let sentence: String
        /// "Step 1 of 2".
        public let stepLine: String
        /// "about 4 s left", only while an estimate exists and has not been passed.
        public let remaining: String?
        /// Past its usual time by a clear margin: say so instead of estimating.
        public let isSlow: Bool
        /// Shown when slow, or from the start on the first launch of a build.
        public let note: String?
        /// 0…1 over the whole load, only while every part of it is an honest estimate.
        public let overall: Double?

        /// The few words beside the track: the time left when there is an honest estimate, that it
        /// is taking longer than usual once it clearly is, and otherwise which step this is (the
        /// track's own segments show the step in the other two cases).
        public var statusLine: String {
            remaining ?? (isSlow ? Self.slowWords : stepLine)
        }

        /// What VoiceOver reads as the progress value.
        public var spokenValue: String {
            var parts = [line, stepLine]
            if let overall { parts.append("\(Int((overall * 100).rounded())) percent") }
            if let remaining { parts.append(remaining.lowercased()) }
            if isSlow { parts.append(Self.slowWords.lowercased()) }
            return parts.joined(separator: ", ")
        }

        public static let slowWords = "Taking longer than usual"
        public static let firstLaunchNote = "The first launch after installing or updating takes longer, sometimes up to a minute."
        public static let slowNote = "This is slower than usual on this Mac. Hushy is still working; nothing is needed from you."
    }

    /// How far past its usual time a stage runs before the card says so: half as long again, and
    /// two seconds, so an ordinary slow second never reads as a problem.
    public static func slowAfter(usual: TimeInterval) -> TimeInterval { usual * 1.5 + 2 }

    public func display(at now: Date) -> Display {
        let shown = finished.map(\.stage) + [stage] + SpeechLoadStage.allCases.filter {
            Self.order($0) > Self.order(stage) && $0 != .checking
        }
        let elapsed = max(0, now.timeIntervalSince(stageStartedAt))
        let expected = usual?[stage]
        let fraction: Double? = expected.flatMap { elapsed < $0 ? elapsed / $0 : nil }
        let isSlow = expected.map { elapsed > Self.slowAfter(usual: $0) } ?? false

        // A stage's share of the track is its usual time; with none to go by, the shares are equal.
        let weights = shown.map { usual?[$0] }
        let known = weights.compactMap { $0 }
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        let segments = zip(shown, weights).map { item, weight -> Display.Segment in
            let step: Display.Step = item == stage ? .current(fraction: fraction)
                : (Self.order(item) < Self.order(stage) ? .done : .pending)
            return Display.Segment(stage: item, step: step, weight: max(weight ?? fallback, fallback * 0.25))
        }

        // Time left and an overall figure only when every stage still to run has a usual time
        // and the current one has not passed its own.
        let later = shown.filter { Self.order($0) > Self.order(stage) }
        var remaining: String?
        var overall: Double?
        if let expected, let fraction, let usual, later.allSatisfy({ usual[$0] != nil }) {
            let left = (expected - elapsed) + later.compactMap { usual[$0] }.reduce(0, +)
            remaining = Self.remainingWords(left)
            let before = finished.map { usual[$0.stage] ?? $0.seconds }.reduce(0, +)
            let total = before + expected + later.compactMap { usual[$0] }.reduce(0, +)
            overall = total > 0 ? min((before + expected * fraction) / total, 1) : nil
        }
        let position = (shown.firstIndex(of: stage) ?? 0) + 1
        return Display(
            segments: segments, line: stage.line, sentence: stage.sentence,
            stepLine: "Step \(position) of \(shown.count)", remaining: remaining, isSlow: isSlow,
            note: isSlow ? (isFirstLaunchOfBuild ? Display.firstLaunchNote : Display.slowNote)
                : (isFirstLaunchOfBuild ? Display.firstLaunchNote : nil),
            overall: overall)
    }

    /// "about 4 s left", "about a minute left": rounded up, never zero, never to the second
    /// beyond a minute.
    public static func remainingWords(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        if whole < 50 { return "About \(whole) s left" }
        if whole < 90 { return "About a minute left" }
        return "About \(Int((Double(whole) / 60).rounded())) min left"
    }
}

/// Where this Mac's load times are kept: one small file in Hushy's data folder. Numbers only.
public struct SpeechLoadTimesStore: Sendable {
    public let url: URL
    /// The running build, so its first launch can be told from the rest.
    public let build: String

    public init(url: URL, build: String) {
        self.url = url
        self.build = build
    }

    /// The file in the app's data folder (`AppPaths`, so a temporary home has its own).
    public static var standard: SpeechLoadTimesStore {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        return SpeechLoadTimesStore(url: AppPaths.supportDirectory.appendingPathComponent("load-times.json"), build: build)
    }

    /// A missing or unreadable file reads as no history: the card then shows stages without times.
    public func read() -> SpeechLoadTimes {
        guard let data = try? Data(contentsOf: url) else { return SpeechLoadTimes() }
        return (try? JSONDecoder().decode(SpeechLoadTimes.self, from: data)) ?? SpeechLoadTimes()
    }

    public func add(_ stages: [String: Double], firstOfBuild: Bool) throws {
        var times = read()
        times.add(.init(build: build, firstOfBuild: firstOfBuild, stages: stages))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(times).write(to: url, options: .atomic)
    }
}
