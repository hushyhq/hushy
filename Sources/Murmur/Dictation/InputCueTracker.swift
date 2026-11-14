import Foundation
import MurmurCore

/// Says when a recording is really being heard.
///
/// A Bluetooth headset delivers exact zeros until its microphone link is up, about a second
/// (2026-10-13 log: "first sound after 1300 ms", every dictation). Whatever is said in that time
/// is lost, and the pill used to show its listening waveform throughout. This watches the levels
/// of one recording: if no sound has arrived after a short grace, the pill says the headset is
/// connecting, and the moment sound arrives it says so no longer. The start sound waits for that
/// moment too, so it means "speak now" on a headset as it does on the Mac's own microphone.
///
/// Only a Bluetooth input gets the cue. On any other microphone exact zeros are not a link coming
/// up, and the recording's own failure row says what happened.
@MainActor
final class InputCueTracker {
    /// How long zeros are ordinary: a wired or built-in microphone delivers sound well inside it.
    static let grace: Duration = .milliseconds(300)
    /// After this long with no sound the pill stops saying "connecting": it no longer knows that.
    static let giveUp: Duration = .seconds(5)

    private let sleep: @Sendable (Duration) async -> Void
    private var generation = 0
    private(set) var hasHeardSound = false
    private var show: ((PillModel.InputCue) -> Void)?
    private var onHeard: (() -> Void)?
    private var onGaveUp: (() -> Void)?

    init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Whether the cue applies to a recording on this kind of input.
    static func waitsForSound(on transport: InputTransport?) -> Bool { transport == .bluetooth }

    /// A recording started on an input of this `transport`. `show` draws the cue; `onHeard` runs
    /// once, when sound first arrives; `onGaveUp` runs once if none has arrived by `giveUp`. The
    /// wait is bounded: a headset that sends only silence ends in a row that says so, never in a
    /// cue that waits for as long as the key is held.
    func begin(transport: InputTransport?, show: @escaping (PillModel.InputCue) -> Void, onHeard: @escaping () -> Void,
               onGaveUp: @escaping () -> Void = {}) {
        generation += 1
        hasHeardSound = false
        self.show = show
        self.onHeard = onHeard
        self.onGaveUp = onGaveUp
        show(.hearing)
        guard Self.waitsForSound(on: transport) else { return }
        let current = generation
        Task { [sleep] in
            await sleep(Self.grace)
            self.set(.connectingHeadset, for: current)
            await sleep(Self.giveUp - Self.grace)
            self.giveUp(for: current)
        }
    }

    private func giveUp(for current: Int) {
        guard generation == current, !hasHeardSound else { return }
        show?(.hearing)
        let gaveUp = onGaveUp
        onGaveUp = nil
        gaveUp?()
    }

    private func set(_ cue: PillModel.InputCue, for current: Int) {
        guard generation == current, !hasHeardSound else { return }
        show?(cue)
    }

    /// One level reading of the recording. The first that is not exact silence ends the wait.
    func level(_ rms: Float) {
        guard !hasHeardSound, rms > 0 else { return }
        hasHeardSound = true
        show?(.hearing)
        onHeard?()
        onHeard = nil
    }

    /// The recording ended. Nothing fires after this.
    func end() {
        generation += 1
        show?(.hearing)
        show = nil
        onHeard = nil
        onGaveUp = nil
    }
}
