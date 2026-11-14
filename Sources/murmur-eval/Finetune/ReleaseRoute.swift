import Foundation
import MurmurCore

/// The settings a dictation to a given app runs with on the release path: the same `PipelineSettings.forDictation` call
/// `DictationController` makes, with the app-wide defaults (`ToneSettings.standard`, the Default mode, no personal
/// dictionary). Level is Polished unless `asSpoken`; the app's kind sets the casual context, the technical-token context
/// and the code context of a code editor. The rules draft is
/// `TextCleaner(options: route.options)`. Nothing here builds options by hand.
struct ReleaseRoute {
    let bundleID: String
    let category: AppCategory
    let settings: PipelineSettings

    var options: CleanupOptions { settings.cleanupOptions }

    init(bundleID: String, asSpoken: Bool = false) {
        var tones = ToneSettings.standard
        tones.isAsSpoken = asSpoken
        let category = AppCategory.classify(bundleID: bundleID, windowTitle: nil)
        let mode = MurmurCore.Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        self.bundleID = bundleID
        self.category = category
        self.settings = PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode, category: category,
            bundleID: bundleID, windowTitle: nil)
    }

    /// What the route is, as plain fields for the output rows.
    var summary: [String: Any] {
        [
            "bundleID": bundleID, "category": category.rawValue, "level": options.level.rawValue,
            "isCasualContext": options.isCasualContext, "isCodeContext": options.isCodeContext,
        ]
    }
}
