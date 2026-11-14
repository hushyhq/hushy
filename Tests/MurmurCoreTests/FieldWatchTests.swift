import XCTest
@testable import MurmurCore

/// Which apps get a second look at a paste, and what is read to make it possible. A lost paste may only be
/// claimed where a read of the field really follows a paste, so the answer is an allowlist: an app is
/// unwatched until it is named.
final class FieldWatchTests: XCTestCase {
    private let probe = LandingProbe(characterCount: 3, selectedLength: 0, caretLocation: 3)

    func testOnlyTheAppleTextViewsWhereAReturnAddsALineAreWatched() {
        XCTAssertEqual(FieldWatch.watchedApps, ["com.apple.TextEdit", "com.apple.Notes", "com.apple.mail"])
    }

    func testChromiumBrowsersThatAreNotOnAnyBrowserListAreNotWatched() {
        let browsers = [
            "company.thebrowser.dia", "com.openai.atlas", "ai.perplexity.comet", "org.chromium.Chromium",
            "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "com.sigmaos.sigmaos.macos", "io.gitlab.librewolf-community.librewolf",
        ]
        for bundleID in browsers { XCTAssertFalse(FieldWatch.watches(bundleID: bundleID), bundleID) }
    }

    func testTerminalsAndComposersWhereReturnSendsOrTheCountMayNotFollowAreNotWatched() {
        let apps = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "com.apple.MobileSMS", "com.apple.dt.Xcode", "com.apple.iWork.Pages",
            "com.apple.Safari", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap",
        ]
        for bundleID in apps { XCTAssertFalse(FieldWatch.watches(bundleID: bundleID), bundleID) }
    }

    func testAnAppNobodyHasHeardOfIsNotWatched() {
        XCTAssertFalse(FieldWatch.watches(bundleID: "com.example.BrandNewEditor"))
        XCTAssertFalse(FieldWatch.watches(bundleID: nil))
    }

    func testAKnownFieldInAWatchedAppIsReadOnceForItsBaseline() {
        for bundleID in FieldWatch.watchedApps {
            var reads = 0
            let baseline = FieldWatch.baseline(answer: .field, bundleID: bundleID, forDictation: true) { reads += 1; return probe }
            XCTAssertEqual(baseline, probe, bundleID)
            XCTAssertEqual(reads, 1, bundleID)
        }
    }

    func testAnUnwatchedAppIsNotReadAtAll() {
        for bundleID in ["com.apple.Terminal", "company.thebrowser.dia", "com.apple.MobileSMS", nil] {
            var reads = 0
            XCTAssertNil(FieldWatch.baseline(answer: .field, bundleID: bundleID, forDictation: true) { reads += 1; return probe }, "\(bundleID ?? "nil")")
            XCTAssertEqual(reads, 0, "\(bundleID ?? "nil"): not read, so key-down costs nothing there")
        }
    }

    func testOnlyAKnownFieldHasABaseline() {
        for answer in [FocusAnswer.unknown, .noField] {
            var reads = 0
            XCTAssertNil(FieldWatch.baseline(answer: answer, bundleID: "com.apple.Notes", forDictation: true) { reads += 1; return probe }, "\(answer)")
            XCTAssertEqual(reads, 0)
        }
    }

    func testAPasteLastOrAVoiceActionTargetPaysForNoBaseline() {
        for bundleID in FieldWatch.watchedApps {
            var reads = 0
            XCTAssertNil(FieldWatch.baseline(answer: .field, bundleID: bundleID, forDictation: false) { reads += 1; return probe }, bundleID)
            XCTAssertEqual(reads, 0, "\(bundleID): nothing watches a paste that is not a dictation, so nothing is read")
        }
    }
}
