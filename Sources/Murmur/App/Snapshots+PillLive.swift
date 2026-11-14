import SwiftUI

/// Review frames for the pill's live words (`PillLiveRow`): both variants, a dictation from the first second to the
/// ✓, light and dark. Written to `<directory>/pill-live/`.
extension Snapshots {
    static let pillLiveStates = [
        "listening-0s", "listening-1s", "listening-3s", "listening-long", "handsfree-long",
        "writing-0.5s", "writing-1.5s", "writing-6s", "done",
    ]

    static func renderPillLive(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        let review = directory.appendingPathComponent("pill-live", isDirectory: true)
        try? FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        for variant in PillLiveVariant.allCases {
            for state in pillLiveStates {
                let pill = PillModel()
                pill.liveVariant = variant
                pill.liveWordsAllowed = true
                pill.state = state.hasPrefix("handsfree") ? .handsFree(startedAt: Date().addingTimeInterval(-42)) : .listening
                pill.setLevels(levels)
                configureLive(pill, state: state)
                let elapsed = state == "writing-0.5s" ? 0.5 : state == "writing-1.5s" ? 1.5 : 6.0
                let view = PillView(model: pill)
                    .environment(\.snapshotWritingElapsed, elapsed)
                    .padding(40)
                    .background(Theme.bgSunken)
                    .environment(\.colorScheme, scheme)
                await capture(view, name: "pill-live-\(variant.rawValue)-\(state)", scheme: scheme,
                              size: CGSize(width: 480, height: 160), directory: review, fixedSize: true)
            }
        }
    }

    private static let heardLong = "Please send the revised lighthouse proposal to Mara before the ferry leaves tomorrow"

    private static func configureLive(_ pill: PillModel, state: String) {
        switch state {
        case "listening-1s": pill.noteHeard("Please send")
        case "listening-3s": pill.noteHeard("Please send the revised proposal")
        case "listening-long", "handsfree-long": pill.noteHeard(heardLong)
        case "writing-0.5s":
            pill.noteHeard(heardLong)
            pill.state = .processing()
        case "writing-1.5s":
            pill.noteHeard(heardLong)
            pill.state = .processing()
            pill.advance(to: .polishing, ink: heardLong + " morning")
        case "writing-6s":
            pill.noteHeard(heardLong)
            pill.state = .processing()
            pill.advance(to: .polishing, ink: heardLong + " morning")
            pill.noteCleanupProgress(
                .init(groupsDone: 1, groupCount: 2, wordsDone: 8, wordCount: 16,
                      latestText: "Please send Mara the revised lighthouse proposal."),
                revision: pill.stateRevision)
        case "done":
            pill.noteHeard(heardLong)
            pill.state = .done(words: 14)
        default: break
        }
    }
}
