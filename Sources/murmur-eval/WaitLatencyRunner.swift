import Foundation
import MurmurCore

/// `murmur-eval wait-latency` — how long a user waits after release, and for what, across a
/// *sequence* of dictations (the model's health carries over from one dictation to the next, as it
/// does in the app). Built for the 2026-09-27 "pill shows the words, then a late unpolished paste"
/// report (DECISIONS "Don't wait for a slow model").
///
/// Modes:
/// - default: dev-set dictations (`Evals/dictation-golden.json`; Clean keeps only the cases whose
///   rules draft makes the model worth asking, Polished keeps all) through the production
///   `SmartCleaner` with its production budgets, one after another with `--gap-ms` between them
///   (the "recording" gap; `SmartCleaner.prewarm()` runs at its start, as the app does at key
///   down). Reports p50/p95/max wait, model use, and how many waits were wasted on a timeout.
/// - `--series N`: N raw model calls with a 12 s budget, to see the real latency distribution
///   (how often a call would miss the 2.4 s budget, and whether slow calls cluster).
/// - `--hammer --duration-s S`: back-to-back model calls for S seconds, to reproduce another
///   process (an eval, another app) contending for the on-device model.
///
/// Record `uptime` alongside every run; the report prints the load average at start and end.
enum WaitLatencyRunner {
    static func run(_ args: Arguments) async throws {
        print("backend: \(LanguageModels.current.identifier) · load \(loadAverage())")
        if args.flag("hammer") {
            await hammer(seconds: Double(args.int("duration-s") ?? 600))
        } else if let count = args.int("series") {
            await series(count, gapMs: args.int("gap-ms") ?? 500)
        } else {
            try await dictations(args)
        }
    }

    private static let drafts = [
        "So the thing with the pricing page is basically that like it doesn't actually say what's free and what's paid right.",
        "The import it it fails on files over like two gigs and we should stream it in chunks.",
        "Can you send the deck to Priya no to Maria before the Thursday meeting?",
        "And I think we should basically just have a simple table you know so it's it's obvious.",
    ]

    /// Back-to-back cleanup calls (Polished's longer prompt) until `seconds` pass.
    static func hammer(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        var count = 0
        while Date() < end {
            _ = await SmartCleaner.debugAsk(draft: drafts[count % drafts.count], budgetMs: 20_000, grammarRepair: true)
            count += 1
        }
        print("hammer: \(count) calls in \(Int(seconds)) s")
    }

    static func series(_ count: Int, gapMs: Int) async {
        var latencies: [Double] = []
        for index in 0..<count {
            let start = ContinuousClock.now
            let answer = await SmartCleaner.debugAsk(draft: drafts[index % drafts.count], budgetMs: 12_000)
            let ms = ModelPace.ms(ContinuousClock.now - start)
            latencies.append(ms)
            print("call \(index + 1): \(Int(ms)) ms\(answer == nil ? " (nil)" : "")")
            try? await Task.sleep(for: .milliseconds(gapMs))
        }
        let budget = 2_400.0
        let slow = latencies.map { $0 > budget }
        let afterSlow = zip(slow, slow.dropFirst()).filter(\.0).map(\.1)
        let afterFast = zip(slow, slow.dropFirst()).filter { !$0.0 }.map(\.1)
        func rate(_ values: [Bool]) -> String {
            values.isEmpty ? "n/a" : "\(values.filter { $0 }.count)/\(values.count)"
        }
        print("""
            series n=\(count) p50 \(Int(percentile(latencies, 0.5))) ms · p95 \(Int(percentile(latencies, 0.95))) ms · \
            max \(Int(latencies.max() ?? 0)) ms · over 2.4 s \(rate(slow)) · \
            over 2.4 s after a slow call \(rate(afterSlow)) · after a fast call \(rate(afterFast)) · load \(loadAverage())
            """)
    }

    static func dictations(_ args: Arguments) async throws {
        let level = args.cleanupLevel
        let options = CleanupOptions(level: level)
        let gapMs = args.int("gap-ms") ?? 1_500
        let limit = args.int("limit") ?? 30
        let cases = try Runners.loadGolden(args).filter { item in
            level == .polished || ModelHints.worthAsking(raw: item.spoken, ruled: TextCleaner(options: options).clean(item.spoken))
        }.prefix(limit)
        let cleaner = SmartCleaner()
        var waits: [Double] = []
        var modelUsed = 0
        var timedOut = 0
        var skipped = 0
        var reasons: [String: Int] = [:]
        for item in cases {
            cleaner.prewarm()
            try? await Task.sleep(for: .milliseconds(gapMs))
            let start = ContinuousClock.now
            let output = await cleaner.clean(item.spoken, options: options)
            let ms = ModelPace.ms(ContinuousClock.now - start)
            waits.append(ms)
            if output.usedModel { modelUsed += 1 }
            let reason = output.rejection ?? (output.usedModel ? "used" : "not asked")
            reasons[reason, default: 0] += 1
            if reason.hasPrefix("timeout") { timedOut += 1 }
            if reason.hasPrefix("skipped") || reason.hasPrefix("breaker") { skipped += 1 }
            print("\(item.id): \(Int(ms)) ms · \(reason)")
        }
        let summary = """
            ### Wait latency (\(level.rawValue), \(waits.count) dictations, \(gapMs) ms gaps) · backend \(LanguageModels.current.identifier)

            p50 \(Int(percentile(waits, 0.5))) ms · p95 \(Int(percentile(waits, 0.95))) ms · max \(Int(waits.max() ?? 0)) ms · \
            model used \(modelUsed)/\(waits.count) · waited for a timeout \(timedOut) · skipped fast \(skipped) · \
            load at end \(loadAverage())

            Reasons: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            """
        print(summary)
        if args.flag("record") { Runners.emit(summary) }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "?" }
        return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }
}
