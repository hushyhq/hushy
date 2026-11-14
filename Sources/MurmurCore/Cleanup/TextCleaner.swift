import Foundation

/// Deterministic, rule-based cleanup of an ASR transcript.
///
/// Runs in well under a millisecond, so it is always applied; an optional language-model
/// pass may refine its output afterwards but is never required.
public struct TextCleaner: Sendable {
    public let options: CleanupOptions

    public init(options: CleanupOptions = CleanupOptions()) {
        self.options = options
    }

    public func clean(_ raw: String) -> CleanupResult {
        let literals = LiteralSyntaxProtection(raw, codeContext: options.isCodeContext)
        var text = options.isCodeContext ? literals.masked : Whitespace.normalize(literals.masked)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return CleanupResult(text: "") }

        // These stages encode English-specific patterns (see below).
        let runEnglishOnlyStages = options.level != .verbatim && options.isEnglishOrUnknown

        var pressEnter = false
        if options.voiceCommandsEnabled {
            let command = VoiceCommands.extractPressEnter(text)
            text = command.text
            pressEnter = command.found
            // "Reach out to Raj, wait, scratch that, just text him…": a retarget keeps the frame
            // ("Text Raj…"). It must run before "scratch that" deletes the clause that holds the
            // name the pronoun refers to (see `FrameCorrection`).
            if runEnglishOnlyStages { text = FrameCorrection.retarget(text) }
            text = VoiceCommands.applyScratchThat(text)
        } else if runEnglishOnlyStages {
            text = FrameCorrection.retarget(text)
        }

        // These stages encode English-specific patterns (filler words, "no/actually/wait"
        // correction cues, English number words for inverse-text-normalization, English list
        // cues) tuned and evaled only on English text. Running them on other languages risks
        // silently mangling text they were never designed to parse — e.g. "no" is a full word
        // in Spanish, not always a correction cue — so they are skipped for any language
        // confidently detected as non-English. Punctuation tidying and voice commands (line
        // breaks, "scratch that") are language-neutral and always run. See
        // .claude/DECISIONS.md ("Multi-language dictation") for the rationale.

        var unresolved = 0
        if runEnglishOnlyStages {
            text = Fillers.remove(text)
            // Sub-word stutter fragments ("c calculate", "th the") before whole-word fillers
            // and self-correction, so a dropped fragment can never be mistaken for the start of
            // a correction cue.
            text = WordFragmentStutter.remove(text)
            // Unambiguous word/phrase stutters ("it's it's", "the problem is the problem is") and
            // an orphan fragment inside a repeated lead-in ("in the w in the"), never a legitimate
            // doubling ("that that", "had had", "so so") — see `StutterCollapse`/`LegitDoubles`.
            text = SpokenGrammar.dropOrphanFragmentInRepeat(text, codeContext: options.isCodeContext)
            if !options.isCodeContext { text = StutterCollapse.apply(text) }
            // "so the report is so the issue is that…": a clause restarted with the same opener.
            text = RestartedOpener.apply(text)
            // Hedge "like" is texting register in a chat app or next to "gonna/lol/rn…": kept
            // there for the model to judge, removed everywhere else (see `TextingRegister`).
            if !(options.isCasualContext || TextingRegister.isCasual(text)) {
                text = DiscourseMarkers.remove(text)
            }
            // Whole-clause restatements ("… No, I just need two carrots") before item-level
            // corrections, so the item rules never half-apply to a restated request.
            // "…, sorry, not X, I mean Y": Y replaces X and the "not" leaves with X.
            text = NotXIMeanY.apply(text)
            text = Restatement.apply(text)
            // Head-noun and keep-the-old-value corrections keep the frame: "the online maps, no,
            // the offline ones" → "the offline maps" (see `FrameCorrection`). Before
            // `SelfCorrection`, whose anchor swap would drop "maps".
            text = FrameCorrection.apply(text)
            // A one-word repair with no comma ("with Ameri sorry Indian accent") keeps the word
            // after the cue — see `FragmentRepair`.
            text = FragmentRepair.apply(text)
            let corrected = SelfCorrection.apply(text)
            text = corrected.text
            unresolved = corrected.unresolvedCues
            // Near-duplicate self-repairs ("stop clock, stopwatch") have no cue word, so they
            // run independently of SelfCorrection; after it, so a cue-based correction on the
            // same span is resolved first and never double-handled here.
            text = SelfRepair.apply(text)
            // Runs after self-correction (so "10, no, 9" still resolves on the words as
            // spoken) and before ListFormatter (so a converted "2.3.1" or "3:30" can never be
            // misread as a "point"-separated or numbered list item). Verbatim keeps the
            // speaker's literal words, so it never applies here.
            text = InverseTextNormalizer.apply(text, codeContext: options.isCodeContext)
            // Work messages and email only: "config slash staging dot yaml" -> config/staging.yaml,
            // "p 99" -> p99, "us east one" -> us-east-1, "pr 482" -> PR 482 (see `SpokenTechnicalTokens`).
            // After number conversion, so spoken numbers from ten up are already digits.
            if let context = options.technicalTokens { text = SpokenTechnicalTokens.apply(text, context: context) }
            if options.americanSpelling, options.isEnglishOrUnknown, !options.isCodeContext {
                text = AmericanSpelling.apply(text)
            }
        }

        if options.voiceCommandsEnabled {
            text = VoiceCommands.applyLineBreaks(text)
        }

        // Code editors/terminals: literal symbol words ("dot", "open paren", "arrow") convert to
        // punctuation *before* casing commands run, so "camel case get user dot name" reads as
        // "camel case get user" + "." + "name" rather than letting the casing phrase's word
        // scanner swallow "dot name" as more identifier words (a bare "dot" is alphanumeric-only
        // once spoken, so nothing would otherwise stop it there). File tags then run at the very
        // end regardless (see below) — `CodeFileTags` already accepts either an already-dotted
        // "index.tsx" or a still-spaced "index tsx", so this ordering doesn't affect it.
        // Punctuation is syntax here, so this runs whether or not voice commands are enabled —
        // matching how `StyleFormatter` already never styles a code context regardless of level.
        if options.isCodeContext {
            if options.voiceCommandsEnabled { text = CodeParagraphBreaks.apply(text) }
            // Spoken symbols ("equals", "comma", quotes, flags, comment delimiters) first, while the
            // casing phrases are still plain words; "dot" and parens next; casing last (see `CodeSymbolGrammar`).
            let quotes = CodeQuotes.Vault()
            text = CodeDigitRuns.apply(text)
            text = CodeSymbolGrammar.apply(text, vault: quotes)
            text = CodeSymbols.apply(text)
            text = CodeBracketNumbers.apply(text)
            text = CasingCommands.apply(text)
            text = CodeSymbolGrammar.tightenCalls(text)
            text = quotes.restore(text)
        }

        if runEnglishOnlyStages {
            text = SpokenAddressNormalizer.apply(text, repairPunctuation: !options.isCodeContext)
            text = ListFormatter.format(text, codeContext: options.isCodeContext)
        }

        // A code context keeps punctuation exactly as spoken: no forced capitalization here
        // (an identifier's casing was just deliberately set above, or the user is dictating a
        // comment verbatim) and no auto terminal period below (see `CleanupOptions.isCodeContext`).
        // Verbatim is literal apart from commands the speaker explicitly issued. In casual
        // messaging, preserve the user's casing too; the app context or clear texting markers
        // are the signals, not guesses from particular words or fixture categories.
        let preserveCasing = options.level == .verbatim || (options.level == .polished && (options.isCasualContext || TextingRegister.isCasual(raw)))
        text = Punctuation.tidy(text, capitalize: !options.isCodeContext && !preserveCasing, preserveSyntax: options.isCodeContext)
        if options.level != .verbatim, !options.isCodeContext {
            if !literals.endsInBacktickLiteral { text = TerminalPunctuation.apply(text) }
            if options.isEnglishOrUnknown {
                // Question marks for every sentence that opens as a question (not just the
                // last), tag questions split off ("…configurable. What do you think?"), and "I"
                // / weekday / month capitalization a lowercase transcript lacks.
                text = QuestionPunctuation.apply(text)
                text = EnglishCasing.apply(text)
            }
        }
        if options.isCodeContext, let vocabulary = options.projectVocabulary {
            text = CodeFileTags.apply(text, vocabulary: vocabulary)
        }
        if runEnglishOnlyStages { text = SpokenAddressNormalizer.apply(text, repairPunctuation: !options.isCodeContext) }
        guard let restored = literals.restore(text) else {
            return CleanupResult(text: raw, pressEnter: false, unresolvedCues: unresolved)
        }
        return CleanupResult(text: restored, pressEnter: pressEnter, unresolvedCues: unresolved)
    }
}
