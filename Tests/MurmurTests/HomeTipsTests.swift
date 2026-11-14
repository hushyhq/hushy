import Foundation
import Testing
@testable import Murmur

@Suite("Home tips")
struct HomeTipsTests {
    private func context(count: Int = 0, unpasted: Bool = false, learns: Bool = true, appTone: Bool = false,
                         dismissed: Set<HomeTip> = []) -> HomeTipContext {
        HomeTipContext(dictationCount: count, hasRecentUnpasted: unpasted, learnsFromEdits: learns,
                       hasAppTone: appTone, dismissed: Set(dismissed.map(\.rawValue)))
    }

    @Test("nothing before the first dictation; then the main gesture")
    func firstSteps() {
        #expect(context().next == nil)
        #expect(context(count: 1).next == .doubleTap)
    }

    @Test("an unpasted dictation today comes first")
    func lostWordsFirst() {
        #expect(context(count: 12, unpasted: true).next == .pasteLast)
    }

    @Test("each tip shows once, until dismissed, then the next relevant one")
    func dismissals() {
        let seen: Set<HomeTip> = [.doubleTap]
        #expect(context(count: 3, dismissed: seen).next == .scratchThat)
        #expect(context(count: 5, dismissed: seen.union([.scratchThat])).next == .learnsFromFixes)
        #expect(context(count: 8, dismissed: seen.union([.scratchThat, .learnsFromFixes])).next == .appTone)
        #expect(context(count: 8, dismissed: Set(HomeTip.allCases)).next == nil)
    }

    @Test("a tip is not shown when it does not apply")
    func relevance() {
        let earlier: Set<HomeTip> = [.doubleTap, .scratchThat]
        #expect(context(count: 9, learns: false, dismissed: earlier).next == .appTone, "learning is off")
        #expect(context(count: 9, appTone: true, dismissed: earlier.union([.learnsFromFixes])).next == nil,
                "an app already has its own tone")
        #expect(context(count: 4, dismissed: earlier).next == nil, "too early for the later tips")
    }

    @Test("the words keep the app's voice and stay short")
    func copy() {
        for tip in HomeTip.allCases {
            let words = tip.title(triggerGlyph: "fn") + " " + tip.line
            #expect(!words.contains("!") && !words.contains("\u{2014}"))
            #expect(!words.localizedCaseInsensitiveContains("simply") && !words.localizedCaseInsensitiveContains("just"))
            #expect(tip.line.split(separator: " ").count <= 14)
        }
    }

    @Test("dismissals are an ordinary setting that survives a relaunch")
    @MainActor
    func stored() throws {
        let suite = "hushy-test-home-tips-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.dismissedHomeTips.insert(HomeTip.scratchThat.rawValue)
        let again = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        #expect(again.dismissedHomeTips == [HomeTip.scratchThat.rawValue])
    }
}
