import AppKit
import MurmurCore
import Observation

/// Plays `PillPreviewScript` on the real pill (the real model, views, panel and coordinator), so
/// its motion can be felt without dictating. Nothing else of the app exists in a preview: no
/// microphone, no recogniser, no model, no key tap, no history. The pill's buttons work, but its
/// copy actions are counted and go nowhere.
@MainActor
@Observable
final class PillPreviewRunner {
    let pill: PillModel
    /// What is on screen now, for the control window.
    private(set) var caption = PillPreviewScript.rest.caption
    private(set) var playing: PillPreviewScene?
    /// 1, 0.5 or 0.25: how fast the script runs, and how fast the pill moves with it.
    var speed: Double = 1 { didSet { applyMotion() } }
    /// Play with the timings the pill had before the one motion language, to compare old with new.
    var usesOldTimings = false { didSet { applyMotion() } }
    /// Reduce Motion for the pill: as the Mac has it, or forced on or off.
    var reduceMotion = PillPreviewReduceMotion.system { didSet { pill.reduceMotionOverride = reduceMotion.override } }
    /// Start again from the top when the reel ends.
    var loops = false
    /// How many times a Copy button was pressed. The text itself is dropped.
    private(set) var copies = 0

    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var skipRequested = false
    @ObservationIgnored private var coordinator: PillCoordinator?

    /// How often the invented microphone reports a level, as the real one does (~33 a second).
    static let voiceTick: Duration = .milliseconds(30)
    /// How long the invented microphone takes to send its first level, as a real one does: the
    /// bars are grey until then.
    static let microphoneWarmUp: Duration = .milliseconds(120)
    /// The words an invented sentence group has: only the share matters.
    static let wordsPerGroup = 20

    private func applyMotion() {
        var motion = usesOldTimings ? PillMotion.legacy : PillMotion.standard
        motion.speed = speed
        pill.motion = motion
    }

    /// `sleep` is the wall clock in the preview; a test passes one that returns at once.
    init(pill: PillModel = PillModel(), sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.pill = pill
        self.sleep = sleep
        pill.showWhenIdle = true
    }

    /// Puts the pill on screen through the app's own coordinator. `makePanel` places it; a test
    /// parks it off every display.
    func show(makePanel: @escaping @MainActor (PillModel) -> PillPanel) {
        let coordinator = PillCoordinator(
            pill: pill, fullScreenDetector: .never, announce: { _ in }, voiceOverRunning: { false },
            makePanel: makePanel, copy: { [weak self] _, _ in self?.copies += 1 })
        self.coordinator = coordinator
        coordinator.show(
            onTapIdle: { [weak self] in self?.play([.quick]) },
            onStop: { [weak self] in self?.skipRequested = true },
            onCancel: { [weak self] in self?.stop() })
    }

    /// Plays these scenes from the top, replacing whatever was playing.
    func play(_ scenes: [PillPreviewScene]) {
        task?.cancel()
        task = Task { [weak self] in await self?.run(scenes) }
    }

    func playAll() { play(PillPreviewScript.reel) }

    /// Stops and returns the pill to rest.
    func stop() {
        task?.cancel()
        task = nil
        playing = nil
        apply(PillPreviewScript.rest)
    }

    /// The script itself. Returns when the scenes have played (again and again while `loops`).
    func run(_ scenes: [PillPreviewScene]) async {
        repeat {
            for scene in scenes {
                playing = scene
                for step in PillPreviewScript.steps(for: scene) + [PillPreviewScript.rest] {
                    guard !Task.isCancelled else { return }
                    apply(step)
                    await hold(step)
                }
            }
        } while loops && !Task.isCancelled
        guard !Task.isCancelled else { return }
        playing = nil
    }

    /// Shows one step on the pill.
    func apply(_ step: PillPreviewStep) {
        caption = step.caption
        let state = PillPreviewScript.stamped(step.state, now: Date())
        if state.showsDictationBars {
            // As a real dictation starts: flat grey bars until the microphone's first level.
            pill.resetLevels()
            pill.awaitFirstAudio()
        }
        switch state {
        case .failed(let failure):
            // "Try again" needs something to call; here it does nothing.
            let nothing: @MainActor () -> Void = {}
            pill.present(failure: failure, retry: failure.canRetry ? nothing : nil)
        case .nameOffer(_, let words, let usedContext):
            // The offer needs its word; the answer goes nowhere.
            pill.present(nameOffer: step.text ?? PillPreviewScript.inventedName, words: words, usedContext: usedContext) { _ in }
        default:
            pill.present(state, text: step.text ?? "")
        }
    }

    /// Stays on a step for its time, feeding the invented microphone while it is open. The pill's
    /// ✓ ends the step early.
    private func hold(_ step: PillPreviewStep) async {
        skipRequested = false
        let pace = max(speed, 0.01)
        let total = step.hold / pace
        let shown = pill.stateRevision
        var reports = step.progress[...]
        var elapsed: Duration = .zero
        while elapsed < total, !Task.isCancelled, !skipRequested {
            // Script time: the step's own seconds, however slowly it is being played.
            let time = (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * pace
            if step.voice != .none, elapsed >= Self.microphoneWarmUp / pace || !step.state.showsDictationBars {
                pill.push(rms: step.voice.rms(at: time))
            }
            while let report = reports.first, report.at <= time {
                reports = reports.dropFirst()
                pill.noteCleanupProgress(
                    CleanupProgress(groupsDone: report.done, groupCount: report.count,
                                    wordsDone: report.done * Self.wordsPerGroup, wordCount: report.count * Self.wordsPerGroup),
                    revision: shown)
            }
            let tick = min(Self.voiceTick, total - elapsed)
            await sleep(tick)
            elapsed += tick
        }
    }
}

/// Reduce Motion for the previewed pill.
enum PillPreviewReduceMotion: String, CaseIterable, Identifiable, Sendable {
    case system, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "As this Mac"
        case .on: "On"
        case .off: "Off"
        }
    }

    /// What the pill is told: nil follows the Mac's setting.
    var override: Bool? {
        switch self {
        case .system: nil
        case .on: true
        case .off: false
        }
    }
}
