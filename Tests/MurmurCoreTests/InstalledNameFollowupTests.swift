import Foundation
import Testing
@testable import MurmurCore

@Suite("Installed name follow-up regressions", .serialized)
struct InstalledNameFollowupTests {
    private func settings(_ names: [String]) -> PipelineSettings {
        PipelineSettings(installedApps: names.map { InstalledAppInfo(bundleID: "test.\($0)", name: $0) })
    }

    @Test("product spelling is not a split into ordinary words")
    func productNames() {
        for name in ["Xcode", "RStudio", "iTerm", "VSCode", "iWork", "Text2Edit", "TextEDit", "TeXtEdit"] {
            #expect(!InstalledNamePolicy.isOrdinary(name), "\(name)")
            #expect(settings([name]).vocabulary.terms.contains { $0.text == name }, "\(name)")
        }
        for name in ["TextEdit", "textedit", "TaskBoard", "DraftPad", "ToDo", "GoHome", "MyNotes"] {
            #expect(InstalledNamePolicy.isOrdinary(name), "\(name)")
        }
    }

    @Test("win-070 keeps opens and every other recognised word")
    func visualStudioCode() {
        let settings = settings(["Visual Studio Code", "RStudio", "Xcode"])
        let draft = "Visual Studio Code opens slowly today."
        let boosted = "Visual RStudio Xcode opens slowly today."
        let guarded = settings.vocabulary.guarded(original: draft, boosted: boosted)
        #expect(guarded == draft)
        #expect(DraftCommonWordGuard.reconcile(draft: draft, release: guarded,
            vocabulary: settings.vocabulary, installedApps: settings.installedApps).text == draft)
        // The candidate CTC run dropped opens outright; it did not reach draft restoration.
        #expect(settings.vocabulary.guarded(original: draft, boosted: "Visual Studio Code slowly today.") == draft)
    }

    @Test("win-011 unknown personal spelling survives installed vocabulary boosting")
    func unknownPerson() {
        let settings = settings(["Ghostty"])
        let original = "Gnosy is leading the interviews this week."
        #expect(settings.vocabulary.guarded(original: original,
            boosted: "Ghostty is leading the interviews this week.") == original)
        #expect(InstalledNameFixer.fix(original, settings: settings) == original)
    }

    @Test("installed boosts require an app cue or close sound match; Dictionary keeps precedence")
    func boostEvidence() {
        let context = settings(["Ghostty", "Claude"]).vocabulary
        #expect(context.guarded(original: "Gnosy said yes.", boosted: "Ghostty said yes.") == "Gnosy said yes.")
        #expect(context.guarded(original: "open Gnosy", boosted: "open Ghostty") == "open Ghostty")
        #expect(context.guarded(original: "Claud said yes.", boosted: "Claude said yes.") == "Claude said yes.")
        let dictionary = VocabularyContext(terms: [VocabularyTerm(text: "Ghostty", source: .installedApp),
                                                 VocabularyTerm(text: "Ghostty", aliases: ["Gnosy"])])
        #expect(dictionary.guarded(original: "Gnosy said yes.", boosted: "Ghostty said yes.") == "Ghostty said yes.")
    }

    @Test("restoring installed names preserves all words in each draft span")
    func restoreSpanWordCount() {
        let settings = settings(["TextEdit", "TaskBoard"])
        for (draft, release) in [
            ("save text edit history today", "save TextEdit today"),
            ("text edit and task board opens slowly", "TextEdit and TaskBoard"),
            ("text edit text edit opens today", "TextEdit TextEdit today"),
        ] {
            let outcome = DraftCommonWordGuard.reconcile(draft: draft, release: release,
                vocabulary: settings.vocabulary, installedApps: settings.installedApps)
            #expect(outcome.repairs > 0)
            #expect(outcome.text == draft)
            #expect(outcome.text.split(whereSeparator: \.isWhitespace).count == draft.split(whereSeparator: \.isWhitespace).count)
        }
    }

    @Test("accepted TextEdit trade-off remains ordinary speech")
    func acceptedTradeoff() {
        let settings = settings(["TextEdit"])
        for (draft, boosted) in [
            ("The settings live in text edit.", "The settings live in TextEdit."),
            ("Text edit is still my favourite scratch pad.", "TextEdit is still my favourite scratch pad."),
        ] {
            #expect(DraftCommonWordGuard.reconcile(draft: draft, release: boosted,
                vocabulary: settings.vocabulary, installedApps: settings.installedApps).text == draft)
        }
    }
}
