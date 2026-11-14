import MurmurCore
import SwiftUI

/// The pill's start, wait and arrival as stills (`pm-*`, light and dark): what changed with the
/// one motion language. Motion itself is seen in the preview (`scripts/pill-preview.sh`); these
/// are its frames.
///
/// `pm-start-grey` is key down before the microphone has sent audio (grey bars, no lime rim) and
/// `pm-start-live` the moment after. `pm-fold-0` to `pm-fold-3` are the listening bars folding
/// into the writing dots over the first quarter second after release. `pm-wait-dots`,
/// `pm-wait-writing` and `pm-wait-still` are the wait in the capsule it keeps from listening;
/// `pm-wait-progress` adds the line for a dictation cleaned sentence group by sentence group,
/// `pm-wait-stall` is the same wait stuck on one group, and `pm-wait-reduced` is the wait under
/// Reduce Motion. `pm-done` and `pm-unchecked` are the two ticks a wait ends in. `pm-sheet` is all
/// of them on one page with captions. `HUSHY_SNAPSHOT_ONLY=pm-` renders just these.
extension Snapshots {
    private static let motionBars = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
    /// Invented.
    private static let motionWords = "Vela toggles the amber beacon before the ferry leaves."

    private struct MotionCase {
        let name: String
        let caption: String
        /// Seconds since release the wait is drawn at.
        var elapsed: TimeInterval = 0
        /// Draw the wait as it is in motion at `elapsed`, not the dots at rest.
        var moves = false
        let pill: @MainActor () -> PillModel
    }

    private static func motionPill(_ configure: (PillModel) -> Void) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        configure(pill)
        return pill
    }

    /// A wait that followed a dictation's bars, with `done` of `count` sentence groups reported
    /// `at` seconds after release (no report when `count` is 0).
    private static func waiting(done: Int = 0, of count: Int = 0, at: TimeInterval = 0, reduced: Bool = false) -> PillModel {
        motionPill { pill in
            pill.state = .listening
            pill.setLevels(motionBars)
            pill.state = .processing()
            if reduced { pill.reduceMotionOverride = true }
            guard count > 0, let since = pill.processingStartedAt else { return }
            for step in 0...done {
                pill.noteCleanupProgress(
                    CleanupProgress(groupsDone: step, groupCount: count, wordsDone: step * 20, wordCount: count * 20),
                    revision: pill.stateRevision, now: since.addingTimeInterval(at))
            }
        }
    }

    private static var motionCases: [MotionCase] {
        [
            MotionCase(name: "start-grey", caption: "Key down, microphone asked for, no audio yet: grey bars, no lime") {
                motionPill { $0.resetLevels(); $0.awaitFirstAudio(); $0.state = .listening }
            },
            MotionCase(name: "start-live", caption: "The first audio has arrived: lime, and the rim") {
                motionPill { $0.resetLevels(); $0.awaitFirstAudio(); $0.state = .listening; $0.push(rms: 0.001) }
            },
            MotionCase(name: "listening", caption: "Speaking") {
                motionPill { $0.state = .listening; $0.setLevels(motionBars) }
            },
            MotionCase(name: "fold-0", caption: "Release: the bars as they stood", elapsed: 0, moves: true) { waiting() },
            MotionCase(name: "fold-1", caption: "80 ms: the bars closing, lime cooling to purple", elapsed: 0.08, moves: true) { waiting() },
            MotionCase(name: "fold-2", caption: "160 ms", elapsed: 0.16, moves: true) { waiting() },
            MotionCase(name: "fold-3", caption: "250 ms: three dots. A paste before this goes from bars to the tick",
                       elapsed: 0.25, moves: true) { waiting() },
            MotionCase(name: "wait-dots", caption: "Under a second: dots, in the capsule it had while listening", elapsed: 0.5) { waiting() },
            MotionCase(name: "wait-writing", caption: "From 1 s", elapsed: 2) { waiting() },
            MotionCase(name: "wait-still", caption: "From 5 s", elapsed: 6) { waiting() },
            MotionCase(name: "wait-progress", caption: "Two of four sentence groups cleaned: a line, as far as the truth",
                       elapsed: 2, moves: true) { waiting(done: 2, of: 4, at: 1.8) },
            MotionCase(name: "wait-stall", caption: "Stuck on the second group for five seconds: the line stays, the dots breathe",
                       elapsed: 6, moves: true) { waiting(done: 1, of: 4, at: 0.9) },
            MotionCase(name: "wait-reduced", caption: "Reduce Motion: still dots, the words and the line still arrive", elapsed: 2) {
                waiting(done: 2, of: 4, at: 1.8, reduced: true)
            },
            MotionCase(name: "done", caption: "Pasted and confirmed") {
                motionPill { $0.state = .done(words: 9) }
            },
            MotionCase(name: "unchecked", caption: "Pasted, field not readable: the quiet row, same motion as the tick") {
                motionPill { $0.present(.pastedUnchecked, text: motionWords) }
            },
        ]
    }

    private static func motionView(_ item: MotionCase) -> some View {
        PillView(model: item.pill())
            .environment(\.snapshotWritingElapsed, item.elapsed)
            .environment(\.snapshotWritingMoves, item.moves)
    }

    static func renderPillMotion(scheme: ColorScheme, directory: URL) async {
        let cases = motionCases
        for item in cases {
            await capture(
                motionView(item).padding(40).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "pm-\(item.name)", scheme: scheme, size: CGSize(width: 480, height: 160),
                directory: directory, fixedSize: true)
        }
        let rowHeight: CGFloat = 64
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .center, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 300, alignment: .leading)
                    motionView(item).frame(width: 360, height: rowHeight)
                }
                .padding(.vertical, 6)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        await capture(sheet, name: "pm-sheet", scheme: scheme,
                      size: CGSize(width: 730, height: 48 + CGFloat(cases.count) * (rowHeight + 13)),
                      directory: directory, fixedSize: true)
    }
}
