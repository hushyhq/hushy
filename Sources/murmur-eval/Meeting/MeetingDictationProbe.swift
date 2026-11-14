import Foundation
import MurmurCore
import Synchronization

/// `murmur-eval meeting --probe-dictation [--probe-no-yield] [--probe-seconds N]`: how long does a dictation-sized
/// cleanup call wait while a meeting summary is running on the same loaded model?
///
/// Every `--probe-seconds` (default 7) a short cleanup call goes to the model the summary shares, as a dictation
/// would; the probe marks a dictation in progress (`ForegroundActivity`) from the key press, `--probe-speak-seconds`
/// (default 3) before the call, as a real dictation is recording first, so the summary yields between its calls. `--probe-no-yield` leaves the mark off: the model is simply shared, which is today's behaviour of any
/// two callers on one MLX engine (one serial queue, a decode cannot be interrupted). Reports the probe call's wall
/// time, which is what a dictation would wait. Needs `--backend local` (the shared instance). No spoken or private
/// text: the probe sentence is invented.
enum MeetingDictationProbe {
    static let sentence = "so um i think we should uh move the review to thursday afternoon if that works for everyone"
    static let instructions = "Clean up this dictated sentence: remove filler words, fix punctuation and capitalisation, keep every fact."

    struct Wait: Codable {
        let afterSeconds: Double
        let milliseconds: Double
        let ok: Bool
    }

    /// Runs `work` while the probe fires at the shared model; returns `work`'s value and each probe call's wait.
    static func during<T: Sendable>(
        shared: any LanguageModel, activity: ForegroundActivity, interval: Duration, markBusy: Bool,
        speak: Duration = .seconds(3), _ work: @Sendable () async -> T
    ) async -> (value: T, waits: [Wait]) {
        let start = ContinuousClock.now
        let finished = Mutex(false)
        let probe = Task { () -> [Wait] in
            var waits: [Wait] = []
            while !finished.withLock({ $0 }) {
                // Sleep in short steps so the probe stops soon after the summary does.
                var slept = Duration.zero
                while slept < interval, !finished.withLock({ $0 }) {
                    try? await Task.sleep(for: .milliseconds(100))
                    slept += .milliseconds(100)
                }
                if finished.withLock({ $0 }) { break }
                if markBusy {
                    activity.set(busy: true)
                    try? await Task.sleep(for: speak)
                }
                let began = ContinuousClock.now
                let ok = (try? await shared.respond(
                    instructions: instructions, prompt: sentence, schema: SmartCleaner.cleanedSchema, options: .greedy)) != nil
                let took = ContinuousClock.now - began
                if markBusy { activity.set(busy: false) }
                waits.append(Wait(afterSeconds: seconds(began - start), milliseconds: seconds(took) * 1_000, ok: ok))
            }
            return waits
        }
        let value = await work()
        finished.withLock { $0 = true }
        // A probe call already on its way is let finish: cancelling it would record a wait that never happened.
        return (value, await probe.value)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func summary(_ waits: [Wait], label: String) -> String {
        let sorted = waits.map(\.milliseconds).sorted()
        guard !sorted.isEmpty else { return "dictation probe (\(label)): no calls (summary finished first)" }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
        let failed = waits.filter { !$0.ok }.count
        return String(
            format: "dictation probe (%@): %d calls, wait p50 %.0f ms, p90 %.0f ms, max %.0f ms, failed %d",
            label, sorted.count, percentile(0.5), percentile(0.9), sorted.last ?? 0, failed)
    }
}
