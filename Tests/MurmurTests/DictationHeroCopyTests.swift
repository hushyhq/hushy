import FluidAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Home's dictation card: what it says for each readiness state, read from the same
/// `DictationReadinessStatus.compute` the sidebar row uses. Invented values only.
@Suite("Home dictation card copy")
@MainActor
struct DictationHeroCopyTests {
    private func copy(
        modelState: SpeechModelStatus.State = .ready,
        microphone: Permissions.Status = .granted,
        accessibility: Permissions.Status = .granted,
        triggerKey: TriggerKey = .fn,
        fnCaptureActive: Bool = true,
        globeKeyConflicts: Bool = false,
        macDictationClashes: Bool = false,
        download: ModelDownloadProgress? = nil,
        meteredPause: Bool = false,
        load: SpeechLoadProgress.Display? = nil
    ) -> DictationHeroCopy {
        let status = DictationReadinessStatus.compute(
            modelState: modelState, microphone: microphone, accessibility: accessibility,
            triggerKey: triggerKey, fnCaptureActive: fnCaptureActive,
            globeKeyConflicts: globeKeyConflicts, macDictationClashes: macDictationClashes,
            download: download, meteredPause: meteredPause)
        return DictationHeroCopy.make(
            status: status, triggerGlyph: triggerKey.glyph, modelState: modelState, download: download, load: load)
    }

    @Test("ready says so and how to start, in the person's own key")
    func ready() {
        let ready = copy(triggerKey: .rightOption, fnCaptureActive: false)
        #expect(ready.stateWord == "Ready")
        #expect(ready.headline == "Dictation is ready.")
        #expect(ready.detail == "Double-tap ⌥ to talk, Enter to paste. Or hold ⌥ while you talk.")
        #expect(ready.fixTitle == nil)
        #expect(ready.progress == nil)
        #expect(ready.isReady)
    }

    @Test("the first how-to line carries the key as its own part, so the card can draw it as a key cap")
    func howToStartLines() {
        let lines = DictationHeroCopy.howToStart(triggerGlyph: "fn")
        #expect(lines.map(\.sentence) == ["Double-tap fn to talk, Enter to paste.", "Or hold fn while you talk."])
        #expect(lines.map(\.key) == ["fn", "fn"])
    }

    @Test("a download says dictation will not work yet, with bytes and time left")
    func downloading() {
        let half = ModelDownloadProgress(fraction: 0.5, expectedBytes: 632_000_000, estimatedSecondsRemaining: 230)
        let downloading = copy(modelState: .downloading(0.5), download: half)
        #expect(downloading.stateWord == "Getting ready")
        #expect(downloading.headline == "Dictation is still downloading.")
        #expect(downloading.detail.contains("will not work until that finishes"))
        #expect(downloading.progressLine == "316 of ~632 MB · about 4 min left")
        #expect(downloading.progress == 0.5)
        #expect(downloading.fixTitle == nil)
        #expect(!downloading.isReady)

        let noBytes = copy(modelState: .downloading(0.42))
        #expect(noBytes.progressLine == nil)
        #expect(noBytes.progress == 0.42)
    }

    @Test("a paused download says why, and offers the way on")
    func paused() {
        let offline = copy(modelState: .paused)
        #expect(offline.headline == "Dictation is waiting for a connection.")
        #expect(offline.detail.contains("back online"))
        #expect(offline.fixTitle == "Try again")

        let metered = copy(modelState: .paused, meteredPause: true)
        #expect(metered.headline == "Dictation is waiting for Wi-Fi.")
        #expect(metered.detail.contains("data allowance"))
        #expect(metered.fixTitle == "Download now")
    }

    @Test("loading says what is happening and promises no duration, with nothing to press")
    func loading() {
        let loading = copy(modelState: .loading)
        #expect(loading.stateWord == "Getting ready")
        #expect(loading.headline == "Dictation is getting ready.")
        #expect(loading.detail == "Hushy is loading the speech model. Dictation will work as soon as it has loaded.")
        #expect(!loading.isReady)
        #expect(loading.fixTitle == nil)
        #expect(loading.progress == nil && loading.progressLine == nil, "no fraction exists, so none is shown")
        #expect(!loading.headline.contains("almost"), "a load that takes half a minute on a busy Mac is not almost anything")
    }

    /// Every state the speech model can be in short of ready.
    nonisolated private static let notReady: [SpeechModelStatus.State] = [
        .idle, .downloading(0.4), .paused, .loading, .failed("no network"), .downloadingVocabulary(0.2),
    ]

    @Test("while the speech model is anything but ready, the card never says dictation is ready",
          arguments: notReady)
    func neverReadyBeforeTheModel(state: SpeechModelStatus.State) {
        let card = copy(modelState: state)
        #expect(!card.isReady)
        #expect(card.stateWord != "Ready")
        #expect(!card.headline.contains("is ready"))
        // The pill refuses a key press in exactly these states (`SpeechModelStatus.isReady`).
        let status = SpeechModelStatus()
        status.update(state)
        #expect(!status.isReady)
    }

    @Test("the card flips to ready the moment the model is, and not before")
    func flipsToReady() {
        let status = SpeechModelStatus()
        status.beginLoad(cached: true, expectedBytes: 0)
        #expect(status.state == .loading, "a model already on this Mac is loading, not downloading")
        #expect(!copy(modelState: status.state).isReady)
        status.markReady()
        #expect(status.isReady)
        let ready = copy(modelState: status.state)
        #expect(ready.isReady && ready.headline == "Dictation is ready.")
    }

    @Test("the pill's row for a key pressed too early and Home's card use the same words")
    func pillAndHomeAgree() {
        let status = SpeechModelStatus()
        status.update(.loading)
        #expect(status.label == SpeechModelStatus.loadingLine)
        #expect(status.label == "Loading the speech model")
        let card = copy(modelState: .loading)
        #expect(card.detail.lowercased().contains(status.label.lowercased()), "\(card.detail)")
        // Downloading: both say the speech model is downloading.
        status.update(.downloading(0.4))
        #expect(status.label.lowercased().contains("speech model"))
        #expect(copy(modelState: .downloading(0.4)).detail.contains("speech model"))
    }

    // MARK: Loading progress

    nonisolated private static let began = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("while the model loads, the card, the pill's row and the menu bar name the same stage, and the words change with it",
          arguments: SpeechLoadStage.allCases)
    func oneStageEverywhere(stage: SpeechLoadStage) throws {
        let status = SpeechModelStatus()
        status.pinForSnapshot(.loading, loadProgress: SpeechLoadProgress(stage: stage, startedAt: Self.began))
        // The pill's row for a key pressed too early and the menu bar both show `label`.
        #expect(status.label == stage.line)
        let display = try #require(status.loadProgress).display(at: Self.began.addingTimeInterval(1))
        let card = copy(modelState: .loading, load: display)
        #expect(card.headline == "Dictation is getting ready.")
        #expect(card.detail == stage.sentence)
        #expect(card.detail.lowercased().contains(stage.line.lowercased()), "\(card.detail)")
        #expect(card.load == display)
        #expect(!card.isReady && card.fixTitle == nil)
        #expect(Set(SpeechLoadStage.allCases.map(\.line)).count == SpeechLoadStage.allCases.count, "each stage has its own words")
    }

    @Test("the engine's reports move the stage on: parts of the model, then the warm-up, then ready")
    func stagesFromTheEngine() {
        let status = SpeechModelStatus()
        status.beginLoad(cached: true, expectedBytes: 0, now: Self.began)
        #expect(status.loadProgress?.stage == .loading)
        #expect(status.loadProgress?.usual == nil, "a status with no store remembers nothing and estimates nothing")
        status.report(DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 0, totalFiles: 0)))
        status.report(DownloadProgress(fractionCompleted: 0.5, phase: .compiling(modelName: "Preprocessor")))
        status.report(DownloadProgress(fractionCompleted: 0.75, phase: .compiling(modelName: "Encoder")))
        status.report(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: "")))
        #expect(status.loadProgress?.partsStarted == 2, "the closing report names no part")
        #expect(status.state == .loading)
        status.beginWarmUp(now: Self.began.addingTimeInterval(3))
        #expect(status.loadProgress?.stage == .warming)
        #expect(status.label == "Warming up the speech model")
        status.markReady(now: Self.began.addingTimeInterval(4))
        #expect(status.loadProgress == nil)
        #expect(status.label == "Ready")
    }

    @Test("a model whose files are still to be checked starts in the checking stage; a download has no stages until it loads")
    func checkingAndDownloading() {
        let checked = SpeechModelStatus()
        checked.beginLoad(cached: true, expectedBytes: 0, checksFirst: true, now: Self.began)
        #expect(checked.loadProgress?.stage == .checking)
        #expect(checked.label == "Checking the speech model")
        checked.report(DownloadProgress(fractionCompleted: 0.5, phase: .compiling(modelName: "Encoder")), now: Self.began.addingTimeInterval(2))
        #expect(checked.loadProgress?.stage == .loading)

        let fresh = SpeechModelStatus()
        fresh.beginLoad(cached: false, expectedBytes: 465_000_000, now: Self.began)
        #expect(fresh.loadProgress == nil)
        fresh.report(DownloadProgress(fractionCompleted: 0.5, phase: .compiling(modelName: "Encoder")), now: Self.began.addingTimeInterval(60))
        #expect(fresh.state == .loading)
        #expect(fresh.loadProgress?.stage == .loading)
    }

    @Test("a load that fails shows the failure, never a bar: the stages go, and so does the card's track")
    func failureShowsNoProgress() {
        struct Broken: Error {}
        let status = SpeechModelStatus()
        status.beginLoad(cached: true, expectedBytes: 0, now: Self.began)
        status.beginWarmUp(now: Self.began.addingTimeInterval(3))
        let stale = status.loadProgress?.display(at: Self.began.addingTimeInterval(4))
        status.markFailed(Broken())
        #expect(status.loadProgress == nil)
        // Even handed a stale display, a failed card carries none.
        let card = copy(modelState: status.state, load: stale)
        #expect(card.load == nil)
        #expect(card.headline == "Dictation could not start.")
        #expect(card.fixTitle == "Try again")
        // A pause is not a load either.
        status.beginLoad(cached: true, expectedBytes: 0, now: Self.began)
        status.markPaused()
        #expect(status.loadProgress == nil)
    }

    @Test("what a load took is remembered for the next launch, the first launch of a build apart from the rest")
    func rememberedBetweenLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-load-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SpeechLoadTimesStore(url: folder.appendingPathComponent("load-times.json"), build: "2300")
        func launch(loading: TimeInterval, warming: TimeInterval) -> SpeechLoadProgress? {
            let status = SpeechModelStatus(loadTimes: store)
            status.beginLoad(cached: true, expectedBytes: 0, now: Self.began)
            let begun = status.loadProgress
            status.beginWarmUp(now: Self.began.addingTimeInterval(loading))
            status.markReady(now: Self.began.addingTimeInterval(loading + warming))
            return begun
        }
        // The first launch of the build: nothing to go by, and it says it is a first launch.
        let first = try #require(launch(loading: 32, warming: 2))
        #expect(first.isFirstLaunchOfBuild && first.usual == nil)
        // The second: an ordinary launch with no ordinary launch behind it yet.
        let second = try #require(launch(loading: 3, warming: 0.5))
        #expect(!second.isFirstLaunchOfBuild && second.usual == nil, "the slow first launch is not this one's estimate")
        // The third has the second to go by.
        let third = try #require(launch(loading: 2, warming: 0.5))
        #expect(third.usual == [.loading: 3, .warming: 0.5])
        #expect(store.read().records.count == 3)
        // A load that failed is not remembered.
        let failing = SpeechModelStatus(loadTimes: store)
        failing.beginLoad(cached: true, expectedBytes: 0, now: Self.began)
        failing.markFailed(CancellationError())
        #expect(store.read().records.count == 3)
    }

    @Test("the second download is described by what it is for")
    func vocabulary() {
        let vocabulary = copy(modelState: .downloadingVocabulary(0.7))
        #expect(vocabulary.headline == "Dictation is still setting up.")
        #expect(vocabulary.detail.contains("names and unusual words"))
        #expect(vocabulary.progressLine == "70% so far")
        #expect(vocabulary.progress == 0.7)
    }

    @Test("a failed or unloaded speech model offers Try again, and keeps the reason it gave")
    func failed() {
        let failed = copy(modelState: .failed("Not enough disk space"))
        #expect(failed.stateWord == "Not working")
        #expect(failed.headline == "Dictation could not start.")
        #expect(failed.note == "Not enough disk space")
        #expect(failed.fixTitle == "Try again")

        let idle = copy(modelState: .idle)
        #expect(idle.headline == "Dictation has not started yet.")
        #expect(idle.fixTitle == "Try again")
        #expect(idle.note == nil)
    }

    @Test("a missing microphone permission says what to allow; denied points at System Settings")
    func microphone() {
        let notAsked = copy(microphone: .notDetermined)
        #expect(notAsked.stateWord == "Needs you")
        #expect(notAsked.headline == "Dictation needs the microphone.")
        #expect(notAsked.fixTitle == "Allow microphone")

        let denied = copy(microphone: .denied)
        #expect(denied.headline == "Dictation needs the microphone.")
        #expect(denied.detail.contains("System Settings"))
        #expect(denied.fixTitle == "Open System Settings")
    }

    @Test("missing Accessibility access names the key it is for")
    func accessibility() {
        let blocked = copy(accessibility: .denied, triggerKey: .rightCommand, fnCaptureActive: false)
        #expect(blocked.headline == "Dictation needs Accessibility access.")
        #expect(blocked.detail.contains("notice when you hold ⌘"))
        #expect(blocked.fixTitle == "Allow Accessibility")
    }

    @Test("a key that macOS uses for something else is a warning with the way to Keyboard settings")
    func keyConflicts() {
        let remapped = copy(fnCaptureActive: false, globeKeyConflicts: true)
        #expect(remapped.stateWord == "Check this")
        #expect(remapped.headline == "fn is set to do something else.")
        #expect(remapped.fixTitle == "Open Keyboard settings")

        let clash = copy(triggerKey: .rightOption, fnCaptureActive: false, macDictationClashes: true)
        #expect(clash.headline == "⌥ also starts macOS Dictation.")
        #expect(clash.fixTitle == "Open Keyboard settings")
    }

    @Test("every state offers a button exactly when the readiness check has a fix")
    func fixMatchesStatus() {
        let states: [SpeechModelStatus.State] = [.idle, .downloading(0.2), .paused, .loading, .ready, .failed("x"), .downloadingVocabulary(0.1)]
        for state in states {
            let status = DictationReadinessStatus.compute(
                modelState: state, microphone: .granted, accessibility: .granted, triggerKey: .fn,
                fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false)
            let made = DictationHeroCopy.make(status: status, triggerGlyph: "fn", modelState: state, download: nil)
            #expect((made.fixTitle != nil) == (status.fix != nil), "\(state)")
        }
    }

    @Test("the card keeps the app's voice: no exclamation marks, em dashes, simply or just")
    func voice() {
        let half = ModelDownloadProgress(fraction: 0.5, expectedBytes: 632_000_000, estimatedSecondsRemaining: 230)
        let all = [
            copy(), copy(modelState: .downloading(0.5), download: half), copy(modelState: .paused),
            copy(modelState: .paused, meteredPause: true), copy(modelState: .loading),
            copy(modelState: .downloadingVocabulary(0.7)), copy(modelState: .failed("")), copy(modelState: .idle),
            copy(microphone: .notDetermined), copy(microphone: .denied), copy(accessibility: .denied),
            copy(fnCaptureActive: false, globeKeyConflicts: true),
            copy(triggerKey: .rightOption, fnCaptureActive: false, macDictationClashes: true),
        ]
        for made in all {
            for sentence in [made.stateWord, made.headline, made.detail, made.fixTitle ?? "", made.progressLine ?? ""] {
                #expect(!sentence.contains("!"), "\(sentence)")
                #expect(!sentence.contains("—"), "\(sentence)")
                let words = sentence.lowercased().split { !$0.isLetter }.map(String.init)
                #expect(!words.contains("simply"), "\(sentence)")
                #expect(!words.contains("just"), "\(sentence)")
            }
        }
    }
}
