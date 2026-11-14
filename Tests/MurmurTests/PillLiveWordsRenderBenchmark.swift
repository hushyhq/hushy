import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Murmur

/// What drawing the live words costs the main thread, Large against Mini. Mini still runs the live draft (cleanup
/// uses it), so the only thing that differs is this drawing: each draft re-lays out and redraws the hosted pill on the
/// main actor, the same actor the release-to-paste path runs on. Invented words; nothing is logged or kept.
///
/// Run: `HUSHY_PILL_RENDER_BENCH=1 swift test --filter PillLiveWordsRenderBenchmark`.
@Suite("Pill live words render cost", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["HUSHY_PILL_RENDER_BENCH"] != nil))
@MainActor
struct PillLiveWordsRenderBenchmark {
    private static let sentence = "let's meet at ten no nine and bring your laptop and the printed slides for the planning review"
        .split(separator: " ").map(String.init)

    /// Median and 90th percentile milliseconds per draft update, laid out and drawn into an off-screen window.
    private func measure(liveWords: Bool, updates: Int = 300) -> (median: Double, p90: Double) {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.state = .listening
        pill.liveWordsAllowed = liveWords
        let host = NSHostingView(rootView: PillView(model: pill))
        let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 480, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var times: [Double] = []
        for index in 0..<updates {
            let words = Self.sentence.prefix(1 + index % Self.sentence.count).joined(separator: " ")
            let start = ContinuousClock.now
            pill.noteHeard(words)
            pill.setLevels((0..<PillModel.barCount).map { Double(($0 + index) % 7) / 7 })
            host.layoutSubtreeIfNeeded()
            host.display()
            let spent = ContinuousClock.now - start
            times.append(Double(spent.components.attoseconds) / 1e15 + Double(spent.components.seconds) * 1_000)
        }
        let sorted = times.dropFirst(20).sorted()
        return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)])
    }

    @Test("Large against Mini, per draft update")
    func compare() {
        _ = measure(liveWords: true, updates: 40)   // warm SwiftUI's caches
        let mini = measure(liveWords: false)
        let large = measure(liveWords: true)
        print(String(format: "pill render per draft update: mini median %.3f ms p90 %.3f ms; large median %.3f ms p90 %.3f ms",
                     mini.median, mini.p90, large.median, large.p90))
        #expect(mini.median <= large.median * 1.5, "Mini draws no more than Large")
    }
}
