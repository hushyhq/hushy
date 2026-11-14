import AppKit
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// The wait between release and paste, as a pure function of time and real progress (`PillWait`).
@Suite("Pill — the wait: one gesture when short, true progress when long")
struct PillWaitTests {
    private let window = PillMotion.standard.directDoneWindow

    private func report(_ done: Int, of count: Int, words: Int = 20) -> CleanupProgress {
        CleanupProgress(groupsDone: done, groupCount: count, wordsDone: done * words, wordCount: count * words)
    }

    // MARK: Short waits

    @Test("inside the first quarter second the bars are still folding: no dots, no label, no line")
    func shortWaitShowsNoDots() {
        let progress = PillWaitProgress(fill: 0.5, advancedAt: 0)
        for elapsed in stride(from: 0.0, to: window, by: 0.01) {
            let frame = PillWait.frame(elapsed: elapsed, progress: progress)
            #expect(!frame.showsDots, "\(elapsed)")
            #expect(frame.rhythm == .folding)
            #expect(frame.label == nil)
            #expect(frame.line == nil)
        }
        #expect(PillWait.frame(elapsed: window).showsDots)
    }

    @Test("the fold only ever moves forward")
    func foldIsMonotonic() {
        var last = -1.0
        for step in 0...60 {
            let fold = PillWait.frame(elapsed: Double(step) * 0.01).fold
            #expect(fold >= last)
            #expect(fold >= 0 && fold <= 1)
            last = fold
        }
    }

    @Test("under Reduce Motion, and with the old timings, the dots are simply there")
    func noFoldWhenReduced() {
        #expect(PillWait.frame(elapsed: 0, reduceMotion: true).showsDots)
        #expect(PillWait.frame(elapsed: 0, motion: .legacy).showsDots)
    }

    // MARK: Labels

    @Test("the words arrive at 1 s and 5 s, as before")
    func labels() {
        #expect(PillWait.frame(elapsed: 0.6).label == nil)
        #expect(PillWait.frame(elapsed: 1.0).label == "Writing…")
        #expect(PillWait.frame(elapsed: 4.9).label == "Writing…")
        #expect(PillWait.frame(elapsed: 5.0).label == "Still writing…")
    }

    @Test("the first words fit the listening capsule, so the pill never shrinks and then grows")
    func firstLabelFitsTheCapsule() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let words = ("Writing…" as NSString).size(withAttributes: [.font: font]).width
        let content = PillFold.dotsWidth + 8 + ceil(words)
        #expect(content + 2 * 10 <= PillMetrics.listening.width)
    }

    // MARK: Progress

    @Test("no line without real progress: one call, no groups, or nothing reported")
    func noLineWithoutProgress() {
        #expect(PillWait.frame(elapsed: 2).line == nil)
        #expect(PillWaitProgress.fill(for: report(1, of: 1)) == nil)
        #expect(PillWaitProgress.fill(for: CleanupProgress(groupsDone: 0, groupCount: 0, wordsDone: 0, wordCount: 0)) == nil)
        #expect(PillWaitProgress.starting(with: report(1, of: 1), at: 0) == nil)
    }

    @Test("the line is the share of words settled, with the paste still to come")
    func lineIsTheTruth() {
        let half = PillWaitProgress.fill(for: report(2, of: 4))
        #expect(half == 0.5 * (1 - PillWaitProgress.deliveryShare))
        #expect(PillWaitProgress.fill(for: report(0, of: 4)) == 0)
    }

    @Test("the line never reaches full while the pill is still waiting")
    func neverFullBeforeDelivery() {
        let everything = PillWaitProgress.fill(for: report(4, of: 4))
        #expect(everything.map { $0 < 1 } == true)
        let frame = PillWait.frame(elapsed: 3, progress: PillWaitProgress(fill: 5, advancedAt: 3))
        #expect(frame.line.map { $0 < 1 } == true)
    }

    @Test("the line never goes backwards, whatever order reports arrive in")
    func neverBackwards() throws {
        var progress = try #require(PillWaitProgress.starting(with: report(2, of: 4), at: 0.1))
        let before = progress.fill
        progress = progress.advanced(by: report(1, of: 4), at: 0.4)
        #expect(progress.fill == before)
        #expect(progress.advancedAt == 0.1, "a report that adds nothing is not a step")
        progress = progress.advanced(by: report(3, of: 4), at: 0.9)
        #expect(progress.fill > before)
        #expect(progress.advancedAt == 0.9)
        progress = progress.advanced(by: report(1, of: 1), at: 1.2)
        #expect(progress.advancedAt == 0.9, "a report with no fraction changes nothing")
    }

    @Test("in a stall the line stops where the truth is and the dots change rhythm")
    func stall() {
        let progress = PillWaitProgress(fill: 0.6, advancedAt: 0.4)
        let moving = PillWait.frame(elapsed: 1.0, progress: progress)
        let stalled = PillWait.frame(elapsed: 0.4 + PillWait.stallAfter + 0.1, progress: progress)
        let later = PillWait.frame(elapsed: 6, progress: progress)
        #expect(moving.rhythm == .flowing)
        #expect(stalled.rhythm == .breathing)
        #expect(later.rhythm == .breathing)
        #expect(moving.line == 0.6 && stalled.line == 0.6 && later.line == 0.6)
        #expect(PillWait.frame(elapsed: 6).rhythm == .flowing, "with nothing reported there is no stall to claim")
    }

    // MARK: The fold's geometry

    @Test("at the start every mark is a listening bar, where the waveform drew it")
    func foldStartsAsBars() {
        let metrics = WaveformMetrics.dictation
        for index in 0..<PillFold.barCount {
            let mark = PillFold.mark(index: index, fold: 0, level: 0.5, metrics: metrics, height: metrics.frameHeight)
            #expect(mark.rect.minX == CGFloat(index) * (metrics.barWidth + metrics.spacing))
            #expect(mark.rect.width == metrics.barWidth)
            #expect(mark.rect.height == metrics.minHeight + metrics.maxExtra * 0.5)
            #expect(mark.purple == 0 && mark.opacity == 1)
        }
    }

    @Test("at the end the nine marks are three dots, centred, at their resting strengths")
    func foldEndsAsDots() {
        let metrics = WaveformMetrics.dictation
        let marks = (0..<PillFold.barCount).map {
            PillFold.mark(index: $0, fold: 1, level: Double($0) / 8, metrics: metrics, height: metrics.frameHeight)
        }
        #expect(Set(marks.map(\.rect.minX)).count == 3)
        for (index, mark) in marks.enumerated() {
            #expect(mark.rect.size == CGSize(width: PillFold.dotSize, height: PillFold.dotSize))
            #expect(abs(mark.rect.midY - metrics.frameHeight / 2) < 0.001)
            #expect(mark.purple == 1)
            #expect(abs(mark.opacity - PillFold.restingOpacity[index / 3]) < 1e-9)
        }
        let left = marks[0].rect.minX, right = marks[8].rect.maxX
        #expect(abs((right - left) - PillFold.dotsWidth) < 0.001)
        #expect(abs((left + right) / 2 - PillFold.barsWidth(metrics) / 2) < 0.001, "the dots sit where the bars' centre was")
    }

    @Test("a mark never leaves the strip on its way")
    func foldStaysInside() {
        let metrics = WaveformMetrics.dictation
        for step in 0...20 {
            for index in 0..<PillFold.barCount {
                let mark = PillFold.mark(index: index, fold: Double(step) / 20, level: 1, metrics: metrics, height: metrics.frameHeight)
                #expect(mark.rect.minX >= -0.001 && mark.rect.maxX <= PillFold.barsWidth(metrics) + 0.001)
                #expect(mark.rect.minY >= -0.001 && mark.rect.maxY <= metrics.frameHeight + 0.001)
            }
        }
    }

    // MARK: The writing view

    @Test("under Reduce Motion the clock still ticks, so Writing… and Still writing… arrive on time")
    @MainActor
    func reducedClockStillTicks() {
        let since = Date(timeIntervalSinceReferenceDate: 1_000)
        let schedule = PillWritingView.reducedSchedule(since: since)
        var ticks = schedule.entries(from: since, mode: .normal).makeIterator()
        var dates: [Date] = []
        for _ in 0..<24 { if let date = ticks.next() { dates.append(date) } }
        #expect(dates.count == 24, "a paused clock gives no ticks, and the label never appears")
        #expect(dates.contains { WritingPhase.phase(after: $0.timeIntervalSince(since)) == .writing })
        #expect(dates.contains { WritingPhase.phase(after: $0.timeIntervalSince(since)) == .stillWriting })
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) <= PillWritingView.reducedTick + 0.001)
        }
        // Slow enough to cost nothing: a few ticks a second, not a frame clock.
        #expect(PillWritingView.reducedTick >= 0.2)
    }

    @Test("the marks keep the bars' width until a word arrives, then step aside for it; other pills are just dots")
    @MainActor
    func marksRoom() {
        let bars = Array(repeating: 0.4, count: PillFold.barCount)
        let dictation = PillWritingView(since: .now, levels: bars)
        #expect(dictation.marksSize(hasLabel: false).width == PillFold.barsWidth(.dictation))
        #expect(dictation.marksSize(hasLabel: true).width == PillFold.dotsWidth)
        let action = PillWritingView(since: .now)
        #expect(action.marksSize(hasLabel: false) == CGSize(width: PillFold.dotsWidth, height: PillFold.dotSize))
        #expect(action.marksSize(hasLabel: true) == action.marksSize(hasLabel: false))
        let side = PillWritingView(since: .now, vertical: true, levels: bars)
        #expect(side.marksSize(hasLabel: false) == CGSize(width: PillFold.dotSize, height: PillFold.dotsWidth))
    }

    // MARK: The listening bars

    @Test("a bar glides from its old level to its new one over one update, then rests there")
    @MainActor
    func barsGlide() {
        let interval = Waveform.levelInterval
        #expect(Waveform.glide(from: 0.2, to: 0.8, elapsed: 0) == 0.2)
        #expect(abs(Waveform.glide(from: 0.2, to: 0.8, elapsed: interval / 2) - 0.5) < 1e-9)
        #expect(Waveform.glide(from: 0.2, to: 0.8, elapsed: interval) == 0.8)
        #expect(Waveform.glide(from: 0.2, to: 0.8, elapsed: 5) == 0.8)
        #expect(Waveform.glide(from: 0.2, to: 0.8, elapsed: -1) == 0.2, "a clock that runs backwards never overshoots")
    }

    @Test("the fold starts from the same heights the listening bars were drawn at")
    func foldMatchesTheWaveform() {
        // `Waveform.centerWeight` for nine bars, as its drawing computes it.
        for index in 0..<PillFold.barCount {
            let waveform = 1 - abs(Double(index) - Double(PillFold.barCount - 1) / 2) / Double(PillFold.barCount) * 0.9
            #expect(PillFold.centreWeight(index: index) == waveform)
        }
        #expect(PillFold.centreWeight(index: 4) == 1)
    }

    @Test("the silent breath is small, and gone by the time speech arrives")
    @MainActor
    func silentBreath() {
        #expect(Waveform.breathDepth * Double(WaveformMetrics.dictation.maxExtra) < 3, "under three points at its deepest")
        #expect(Waveform.silenceCeiling < 0.15)
    }
}
