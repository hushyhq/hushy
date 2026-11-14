import MurmurCore
import SwiftUI

/// Home's dictation card while the speech model loads (`lp-*`, light and dark): just started,
/// midway, the last stage, a slow first launch well past its remembered time, a Mac with nothing
/// remembered yet, then ready and failed for comparison. `lp-sheet` is all of them in order.
/// `HUSHY_SNAPSHOT_ONLY=lp-` renders just these. The moment of each still is fixed; a still cannot
/// show the fill moving or a segment breathing.
extension Snapshots {
    private struct LoadCase {
        let name: String
        let caption: String
        let state: SpeechModelStatus.State
        var progress: SpeechLoadProgress?
        var elapsed: TimeInterval = 0
    }

    private static let loadBegan = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let usualLoad: [SpeechLoadStage: TimeInterval] = [.loading: 4, .warming: 1]

    private static var loadCases: [LoadCase] {
        var lastStage = SpeechLoadProgress(startedAt: loadBegan, usual: usualLoad)
        lastStage.enter(.warming, at: loadBegan.addingTimeInterval(3.5))
        return [
            LoadCase(name: "started", caption: "Just started. This Mac usually takes about five seconds.", state: .loading,
                     progress: SpeechLoadProgress(startedAt: loadBegan, usual: usualLoad), elapsed: 0.5),
            LoadCase(name: "midway", caption: "Midway through loading.", state: .loading,
                     progress: SpeechLoadProgress(startedAt: loadBegan, usual: usualLoad), elapsed: 2.5),
            LoadCase(name: "last-stage", caption: "The last stage: loaded, warming up.", state: .loading,
                     progress: lastStage, elapsed: 4),
            LoadCase(name: "slow-first-launch",
                     caption: "A slow first launch after an update, well past the 24 s the last one took: no fraction, no time left.",
                     state: .loading,
                     progress: SpeechLoadProgress(startedAt: loadBegan, usual: [.loading: 22, .warming: 2], isFirstLaunchOfBuild: true),
                     elapsed: 48),
            LoadCase(name: "nothing-remembered", caption: "Nothing remembered yet on this Mac: stages only, no time.", state: .loading,
                     progress: SpeechLoadProgress(startedAt: loadBegan), elapsed: 6),
            LoadCase(name: "ready", caption: "Ready.", state: .ready),
            LoadCase(name: "failed", caption: "Failed: the existing failure state, no bar.", state: .failed("The model files could not be read.")),
        ]
    }

    /// Home's column at the default window size with the Assistant pane open: the narrowest the
    /// card usually is.
    private static let loadCardWidth: CGFloat = 612

    private static func loadCard(_ item: LoadCase) -> some View {
        let status = DictationReadinessStatus.compute(
            modelState: item.state, microphone: .granted, accessibility: .granted, triggerKey: .fn, fnCaptureActive: true,
            globeKeyConflicts: false, macDictationClashes: false, download: nil, meteredPause: false)
        let now = loadBegan.addingTimeInterval(item.elapsed)
        let copy = DictationHeroCopy.make(
            status: status, triggerGlyph: TriggerKey.fn.glyph, modelState: item.state, download: nil,
            load: item.progress?.display(at: now))
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(item.caption).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            DictationHeroCard(
                copy: copy, kind: status.kind, triggerGlyph: TriggerKey.fn.glyph,
                content: HomeCardContent.make(isLocked: false, dictations: [], isReady: copy.isReady, now: now, calendar: .current),
                onFix: {}, onCopy: { _ in }, onOpenInHistory: { _ in }, onUnlock: {})
        }
        .frame(width: loadCardWidth, alignment: .leading)
    }

    static func renderLoadingProgress(scheme: ColorScheme, directory: URL) async {
        let cases = loadCases
        let cardHeight: CGFloat = 330
        for item in cases {
            await capture(
                loadCard(item).padding(24).frame(maxHeight: .infinity, alignment: .top).background(Theme.bgBase).environment(\.colorScheme, scheme),
                name: "lp-\(item.name)", scheme: scheme, size: CGSize(width: loadCardWidth + 48, height: cardHeight),
                directory: directory, fixedSize: true)
        }
        let sheet = VStack(alignment: .leading, spacing: 28) {
            ForEach(cases, id: \.name) { loadCard($0) }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgBase)
        .environment(\.colorScheme, scheme)
        await capture(sheet, name: "lp-sheet", scheme: scheme,
                      size: CGSize(width: loadCardWidth + 48, height: CGFloat(cases.count) * 330 + 60),
                      directory: directory, fixedSize: true)
    }
}
