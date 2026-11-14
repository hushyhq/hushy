import Foundation
import Testing

@testable import MurmurCore

/// The sentence on the Style page and in onboarding must be what the code types.
@Suite("Tone examples")
struct ToneExamplesTests {
    @Test("each choice shows exactly this text: the stored model-cleaned sentence and what the rules do to it")
    func pinned() {
        #expect(ToneExamples.text(for: .refined)
            == "The deploy is gonna go out at five, and we do not need the rollback plan. Can you ping Omar if it fails?")
        #expect(ToneExamples.text(for: .casual)
            == "The deploy is gonna go out at five, and we don't need the rollback plan. Can you ping Omar if it fails?")
        #expect(ToneExamples.text(for: .professional)
            == "The deploy is going to go out at five, and we do not need the rollback plan. Can you ping Omar if it fails?")
        #expect(ToneExamples.text(for: .asSpoken)
            == "so uh the deploy is gonna go out at four no five and we do not need the rollback plan can you ping omar if it fails")
    }

    @Test("the one-sentence version for small cards is the first sentence and keeps every difference")
    func shortVersion() {
        #expect(ToneExamples.cleaned.hasPrefix(ToneExamples.cleanedFirstSentence))
        #expect(ToneExamples.shortText(for: .refined) == "The deploy is gonna go out at five, and we do not need the rollback plan.")
        #expect(ToneExamples.shortText(for: .casual) == "The deploy is gonna go out at five, and we don't need the rollback plan")
        #expect(ToneExamples.shortText(for: .professional) == "The deploy is going to go out at five, and we do not need the rollback plan.")
        #expect(ToneExamples.shortText(for: .asSpoken) == ToneExamples.asSpoken)
        #expect(Set(ToneChoice.allCases.map(ToneExamples.shortText(for:))).count == 4)
    }

    @Test("the stored cleaned sentence is the Hushy model's recorded output, so the rules leave Refined as it is")
    func refinedIsTheCleanedSentence() {
        #expect(ToneExamples.text(for: .refined) == ToneExamples.cleaned)
    }

    @Test("the four examples differ from one another")
    func distinct() {
        #expect(Set(ToneChoice.allCases.map(ToneExamples.text(for:))).count == 4)
    }

    @Test("each tone line is the real output of the rules on the cleaned sentence")
    func toneLinesAreRealOutput() {
        for tone in DictationTone.allCases {
            #expect(ToneExamples.text(for: ToneChoice(tone: tone))
                == ToneRegister.apply(tone, to: ToneExamples.cleaned, in: .other))
        }
    }

    @Test("a tone adds no word outside its own closed set")
    func nothingInvented() {
        for tone in DictationTone.allCases {
            let introduced = ToneRegister.introducedWords(from: ToneExamples.cleaned, to: ToneExamples.text(for: ToneChoice(tone: tone)))
            #expect(Set(introduced.keys).isSubset(of: ToneRegister.closedIntroductions(for: tone)), "\(tone): \(introduced)")
        }
    }

    @Test("As spoken is what verbatim cleanup leaves of the spoken sentence")
    func asSpokenIsWhatVerbatimDoes() {
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim)).clean(ToneExamples.spoken).text
        #expect(verbatim == ToneExamples.asSpoken)
    }

    @Test("the layouts of every tone example are the layouts the Style page promises")
    func everyDestination() {
        for context in StyleContext.allCases {
            let refined = ToneRegister.apply(.refined, to: ToneExamples.cleaned, in: context)
            let professional = ToneRegister.apply(.professional, to: ToneExamples.cleaned, in: context)
            #expect(refined.hasSuffix("fails?"), "\(context)")
            #expect(professional.contains("going to"), "\(context)")
        }
    }

    @Test("each tone claims only what its line shows")
    func claimsMatchWhatIsShown() {
        // Casual shows contractions; Professional shows spelled-out forms; Refined keeps the words.
        let casual = ToneExamples.text(for: .casual), refined = ToneExamples.text(for: .refined)
        #expect(casual.contains("don't") && refined.contains("do not"))
        #expect(ToneExamples.text(for: .professional).contains("going to") && refined.contains("gonna"))
        #expect(ToneChoice.casual.detail.contains("contractions") && !ToneChoice.casual.detail.contains("friendly"))
        #expect(ToneChoice.professional.detail.contains("spelled out") && !ToneChoice.professional.detail.contains("Polished"))
    }

    @Test("the words around the choice are plain, and say nothing about accuracy or the model")
    func copyIsPlain() {
        var lines = [ToneCopy.tonesStillApply, ToneCopy.pausedByAsSpoken, ToneCopy.writingPointerTitle,
                     ToneCopy.polishStatusTitle, ToneCopy.voiceCommandsTitle,
                     ToneCopy.voiceCommandsDetail, ToneCopy.americanSpellingTitle, ToneCopy.americanSpellingDetail,
                     ToneCopy.pageBanner, ToneCopy.onboardingTitle,
                     ToneCopy.onboardingMessage(spoken: ToneExamples.spoken), ToneCopy.appsTitle,
                     ToneCopy.onboardingAppsDetail, ToneCopy.promptName,
                     ToneCopy.comingBadge, ToneCopy.codeAppsLeftAlone, ToneCopy.browsersNeedKind, ToneCopy.noToneInCode,
                     ToneCopy.codeKindNote, ToneCopy.nothingFoundHere, ToneCopy.websitesNote,
                     ToneCopy.aiToolsNote(.standard), ToneCopy.moreApps(3),
                     ToneCopy.asSpokenEveryAppTitle, ToneCopy.asSpokenEveryAppDetail, ToneCopy.otherWebsite,
                     ToneCopy.websiteNotAddress, ToneCopy.websiteKeptNote, ToneCopy.removeWebsite,
                     ToneCopy.laneDetail(.asSpoken, registerLines: true),
                     ToneCopy.noToneFootnote(["Cursor", "Terminal"])]
        lines += StyleContext.allCases.flatMap { [ToneCopy.kindChipName($0), ToneCopy.kindChipHelp($0)] }
        lines += ToneChoice.allCases.map(\.detail) + ToneChoice.allCases.map(\.title)
        for context in StyleContext.allCases {
            lines.append(ToneCopy.destinationNote(.standard, for: context))
            lines.append(ToneCopy.destinationNote(.standard.settingTone(.casual, for: context), for: context))
            lines.append(ToneCopy.destinationNote(
                ToneSettings.migrated(from: .init(cleanupLevel: nil, styles: [context.rawValue: "excited"], isExistingInstall: true)),
                for: context))
        }
        let banned = ["%", "accura", "percent", "model", "Apple", "Qwen", "LLM", "AI ", "Intelligence", "Cleaned up"]
        for line in lines {
            for word in banned { #expect(!line.contains(word), "“\(line)” contains \(word)") }
        }
    }

    @Test("the words for the choices that moved to Voice & style are in the app's voice")
    func movedChoicesKeepTheAppVoice() {
        #expect(ToneCopy.voiceCommandsDetail
            == "Say “new line”, “new paragraph”, “scratch that” or “press enter” and Hushy does it instead of writing the words.")
        #expect(ToneCopy.americanSpellingDetail
            == "Rewrites British spellings Hushy hears (“colour”, “programme”) to American ones (“color”, “program”).")
        let lines = [ToneCopy.writingPointerTitle, ToneCopy.polishStatusTitle,
                     ToneCopy.tonesStillApply, ToneCopy.voiceCommandsTitle, ToneCopy.voiceCommandsDetail,
                     ToneCopy.americanSpellingTitle, ToneCopy.americanSpellingDetail]
        for line in lines {
            for word in ["!", "\u{2014}", "simply", "just ", "Just "] { #expect(!line.contains(word), "“\(line)” contains \(word)") }
        }
    }
}
