import Foundation
import Testing
@testable import MurmurCore

/// What Home shows while the speech model loads: real stages, and time only where this Mac's
/// earlier launches give something to go by. The clock is the test's.
@Suite("Speech model load progress")
struct SpeechLoadProgressTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let usual: [SpeechLoadStage: TimeInterval] = [.loading: 4, .warming: 1]

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func steps(_ display: SpeechLoadProgress.Display) -> [SpeechLoadProgress.Display.Step] {
        display.segments.map(\.step)
    }

    // MARK: Stages

    @Test("the stages come in order: load, then warm up; each finished one is done and the rest wait")
    func stageOrder() {
        var progress = SpeechLoadProgress(startedAt: start)
        var display = progress.display(at: at(1))
        #expect(display.segments.map(\.stage) == [.loading, .warming])
        #expect(steps(display) == [.current(fraction: nil), .pending])
        #expect(display.line == "Loading the speech model")
        #expect(display.stepLine == "Step 1 of 2")

        progress.enter(.warming, at: at(3))
        display = progress.display(at: at(3.25))
        #expect(steps(display) == [.done, .current(fraction: nil)])
        #expect(display.line == "Warming up the speech model")
        #expect(display.stepLine == "Step 2 of 2")
        #expect(progress.finished.map(\.stage) == [.loading])
        #expect(progress.finished.first?.seconds == 3)
    }

    @Test("a stage never goes back: a late report of an earlier stage changes nothing")
    func stagesOnlyGoForward() {
        var progress = SpeechLoadProgress(startedAt: start)
        progress.enter(.warming, at: at(3))
        let warm = progress
        progress.enter(.loading, at: at(4))
        progress.enter(.warming, at: at(5))
        #expect(progress == warm)
    }

    @Test("the check of the model's files is a stage only on a launch that runs it")
    func checkingOnlyWhenItRuns() {
        var progress = SpeechLoadProgress(stage: .checking, startedAt: start)
        #expect(progress.display(at: at(1)).segments.map(\.stage) == [.checking, .loading, .warming])
        #expect(progress.display(at: at(1)).stepLine == "Step 1 of 3")
        #expect(progress.display(at: at(1)).line == "Checking the speech model")
        progress.enter(.loading, at: at(2))
        #expect(steps(progress.display(at: at(2.5))) == [.done, .current(fraction: nil), .pending])
    }

    @Test("the model's parts are counted as Core ML starts on them, in the loading stage only")
    func parts() {
        var progress = SpeechLoadProgress(startedAt: start)
        progress.partStarted()
        progress.partStarted()
        #expect(progress.partsStarted == 2)
        progress.enter(.warming, at: at(3))
        progress.partStarted()
        #expect(progress.partsStarted == 2)
    }

    // MARK: Unknown length

    @Test("with nothing remembered a stage is shown as in progress: no fraction, no time left, no percentage")
    func unknownLength() {
        let progress = SpeechLoadProgress(startedAt: start)
        for seconds in [0.0, 2, 30, 300] {
            let display = progress.display(at: at(seconds))
            #expect(steps(display) == [.current(fraction: nil), .pending])
            #expect(display.remaining == nil)
            #expect(display.overall == nil)
            #expect(!display.isSlow, "with no usual time nothing can be called slow")
            #expect(!display.spokenValue.contains("percent"))
            #expect(display.statusLine == "Step 1 of 2", "with no time to give, the words say which step")
        }
        // The two stages share the track evenly.
        let weights = progress.display(at: at(1)).segments.map(\.weight)
        #expect(weights[0] == weights[1])
    }

    @Test("a stage with no remembered time beside one that has: no time left is promised for the whole")
    func partlyKnown() {
        let progress = SpeechLoadProgress(startedAt: start, usual: [.loading: 4])
        let display = progress.display(at: at(1))
        #expect(steps(display) == [.current(fraction: 0.25), .pending])
        #expect(display.remaining == nil)
        #expect(display.overall == nil)
    }

    // MARK: Remembered time

    @Test("with a remembered time the stage fills as that time passes, and the rest is the time left")
    func remembered() {
        var progress = SpeechLoadProgress(startedAt: start, usual: usual)
        var display = progress.display(at: at(1))
        #expect(steps(display) == [.current(fraction: 0.25), .pending])
        #expect(display.remaining == "About 4 s left")
        #expect(display.overall == 0.2)
        #expect(display.segments.map(\.weight) == [4, 1], "each stage is as wide as it usually takes")
        #expect(display.spokenValue == "Loading the speech model, Step 1 of 2, 20 percent, about 4 s left")
        #expect(display.statusLine == "About 4 s left", "the segments show the step; the words give the time")

        progress.enter(.warming, at: at(4))
        display = progress.display(at: at(4.5))
        #expect(steps(display) == [.done, .current(fraction: 0.5)])
        #expect(display.remaining == "About 1 s left")
        #expect(display.overall == 0.9)
    }

    @Test("this launch slower than remembered: the stage stops filling when its usual time is up, and soon says so")
    func slowerThanRemembered() {
        let progress = SpeechLoadProgress(startedAt: start, usual: usual)
        // Just short of its usual time: nearly full, still an estimate.
        #expect(steps(progress.display(at: at(3.75)))[0] == .current(fraction: 0.9375))
        // At and past it: in progress, no fraction, no time left. Never a full bar that waits.
        for seconds in [4.0, 5, 7.75] {
            let display = progress.display(at: at(seconds))
            #expect(steps(display)[0] == .current(fraction: nil), "\(seconds)")
            #expect(display.remaining == nil)
            #expect(display.overall == nil)
            #expect(!display.isSlow, "an ordinary slow second or two is not called slow")
        }
        // Half as long again and two seconds: now it is said.
        let slow = progress.display(at: at(30))
        #expect(slow.isSlow)
        #expect(slow.statusLine == "Taking longer than usual")
        #expect(slow.note == SpeechLoadProgress.Display.slowNote)
        #expect(!slow.spokenValue.contains("percent"))
        #expect(SpeechLoadProgress.slowAfter(usual: 4) == 8)
    }

    @Test("this launch faster than remembered: a stage that ends early is done at once and the next begins")
    func fasterThanRemembered() {
        var progress = SpeechLoadProgress(startedAt: start, usual: usual)
        #expect(progress.display(at: at(0.25)).overall == 0.05)
        progress.enter(.warming, at: at(0.5))
        let display = progress.display(at: at(0.5))
        #expect(steps(display) == [.done, .current(fraction: 0)])
        // The figure goes forward to the stage's edge; it never goes back.
        #expect(display.overall == 0.8)
        #expect(display.remaining == "About 1 s left")
        #expect(progress.durations(endingAt: at(0.75))["loading"] == 0.5)
    }

    @Test("the first launch of a build says from the start that it takes longer")
    func firstLaunchOfBuild() {
        let first = SpeechLoadProgress(startedAt: start, usual: [.loading: 30, .warming: 2], isFirstLaunchOfBuild: true)
        let display = first.display(at: at(3))
        #expect(display.note == SpeechLoadProgress.Display.firstLaunchNote)
        #expect(display.remaining == "About 29 s left")
        // With no earlier first launch to go by: the note, and stages without times.
        let unknown = SpeechLoadProgress(startedAt: start, isFirstLaunchOfBuild: true).display(at: at(20))
        #expect(unknown.note == SpeechLoadProgress.Display.firstLaunchNote)
        #expect(unknown.remaining == nil && unknown.overall == nil)
    }

    @Test("time left is rounded up, never zero, and never to the second beyond a minute")
    func remainingWords() {
        #expect(SpeechLoadProgress.remainingWords(0.2) == "About 1 s left")
        #expect(SpeechLoadProgress.remainingWords(3.1) == "About 4 s left")
        #expect(SpeechLoadProgress.remainingWords(49) == "About 49 s left")
        #expect(SpeechLoadProgress.remainingWords(55) == "About a minute left")
        #expect(SpeechLoadProgress.remainingWords(150) == "About 3 min left")
    }

    // MARK: What is remembered

    @Test("the usual time is the middle one of earlier launches of the same kind; first launches of a build are kept apart")
    func usualTimes() {
        var times = SpeechLoadTimes()
        #expect(times.usual(firstOfBuild: false) == nil)
        #expect(times.isFirstLaunch(of: "2215"))
        times.add(.init(build: "2215", firstOfBuild: true, stages: ["loading": 31, "warming": 2]))
        #expect(!times.isFirstLaunch(of: "2215"))
        #expect(times.isFirstLaunch(of: "2216"))
        #expect(times.usual(firstOfBuild: false) == nil, "one slow first launch says nothing about an ordinary one")
        for seconds in [2.0, 3, 9] {
            times.add(.init(build: "2215", firstOfBuild: false, stages: ["loading": seconds, "warming": 0.5]))
        }
        #expect(times.usual(firstOfBuild: false) == [.loading: 3, .warming: 0.5], "one slow launch does not move the middle")
        #expect(times.usual(firstOfBuild: true) == [.loading: 31, .warming: 2])
        // A launch that recorded nothing is not kept, and only the latest dozen are.
        times.add(.init(build: "2215", firstOfBuild: false, stages: [:]))
        #expect(times.records.count == 4)
        for _ in 0..<20 { times.add(.init(build: "2216", firstOfBuild: false, stages: ["loading": 1])) }
        #expect(times.records.count == SpeechLoadTimes.limit)
    }

    @Test("load times are kept in one small file, and a missing or damaged file reads as no history")
    func store() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-load-times-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SpeechLoadTimesStore(url: folder.appendingPathComponent("load-times.json"), build: "2215")
        #expect(store.read() == SpeechLoadTimes())
        try store.add(["loading": 3.5, "warming": 0.4], firstOfBuild: true)
        try store.add(["loading": 2.5, "warming": 0.4], firstOfBuild: false)
        let read = store.read()
        #expect(read.records.map(\.firstOfBuild) == [true, false])
        #expect(read.usual(firstOfBuild: false) == [.loading: 2.5, .warming: 0.4])
        // Numbers and a build only.
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("2215") && text.contains("loading"))
        try Data("not json".utf8).write(to: store.url)
        #expect(store.read() == SpeechLoadTimes())
    }

    @Test("what is remembered from a load is every stage it went through, with the last one ending when the model is ready")
    func durations() {
        var progress = SpeechLoadProgress(stage: .checking, startedAt: start)
        progress.enter(.loading, at: at(2))
        progress.enter(.warming, at: at(7))
        #expect(progress.durations(endingAt: at(7.5)) == ["checking": 2, "loading": 5, "warming": 0.5])
    }
}
