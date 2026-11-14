import Foundation

/// Experimental / gated features that ship in the binary. Centralizing these here (rather than
/// scattering raw `UserDefaults` reads) gives every flag one documented default and one place a
/// reviewer checks when asking "is this on for real users."
///
/// Most flags are on by default (founder, 2026-09-28); `personMemory` and `taskHandoff`
/// are explicit off-by-default exceptions. Storing `false` under an on-default flag is its kill switch
/// (`defaults write app.hushy.Hushy <key> -bool false`, or Settings → Developer in DEBUG). To gate a
/// feature for release, change its default here and update the flag table in
/// `handbook/src/content/docs/architecture/feature-flags.mdx`.
public enum FeatureFlags {
    /// Person memory is absent unless explicitly enabled.
    public static var personMemory: Bool {
        get { isExplicitlyOn(personMemoryKey, in: source) }
        set { source.set(newValue, forKey: personMemoryKey) }
    }
    /// Installed app names in ASR vocabulary and post-ASR name correction.
    public static var installedNames: Bool {
        get { enabled(installedNamesKey) }
        set { UserDefaults.standard.set(newValue, forKey: installedNamesKey) }
    }
    /// Temporary vocabulary from the focused field and window title, for one dictation.
    public static var screenContextSpelling: Bool {
        get { enabled(screenContextSpellingKey) }
        set { UserDefaults.standard.set(newValue, forKey: screenContextSpellingKey) }
    }
    /// The personal lexicon (`PersonalLexicon`): names from History, edits, meeting attendees and domain packs that the
    /// person's own screen and History switch on, boosted in the recogniser. Off means the vocabulary is what it was.
    public static var personalLexicon: Bool {
        get { enabled(personalLexiconKey) }
        set { source.set(newValue, forKey: personalLexiconKey) }
    }
    /// The paste glow: a faint blue wash that fades over the field a dictation was pasted into
    /// (`PasteGlow`), shown only in Hushy's own windows (the onboarding practice chat). Visual only;
    /// it reads the field's frame, never its text.
    public static var pasteGlow: Bool {
        get { enabled(pasteGlowKey) }
        set { source.set(newValue, forKey: pasteGlowKey) }
    }
    /// Meeting-app browser recognition: a mic-using browser's window titles refine the generic
    /// "browser meeting" label to Google Meet, Teams or Zoom. The generic call prompt is separate.
    public static var meetingAppIntegration: Bool {
        get { enabled(meetingAppIntegrationKey) }
        set { UserDefaults.standard.set(newValue, forKey: meetingAppIntegrationKey) }
    }

    /// Offers "Encrypt recordings" in Privacy & Security (a key in the login Keychain, see
    /// `EncryptionController`). It covers audio files only, not the SQLite database (GRDB's
    /// SQLCipher SPM trait isn't released yet — see `.claude/DECISIONS.md`). The flag gates only
    /// *offering* the toggle and running the enable migration the user starts, never decrypting
    /// files that are already encrypted.
    public static var recordingEncryption: Bool {
        get { enabled(recordingEncryptionKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordingEncryptionKey) }
    }

    /// Cleaning finished sentence groups while a dictation is still being spoken (see `EarlyCleanupSession`; until
    /// 2026-10-12 this switched a separate while-speaking recogniser, hence the name).
    /// **On by default for everyone** as of the 2026-09-26 measurement in `.claude/DECISIONS.md`
    /// (streaming matched or beat whole-utterance release-to-text latency at 30 s+ with no WER
    /// regression, both idle and under load) — this supersedes the earlier "off until a
    /// real-time-paced eval shows a win" default. In a release build this getter always returns
    /// `true` and the setter is a no-op: the flag now exists only as a DEBUG-only kill switch
    /// (Developer settings pane) for isolating a regression on one machine while debugging, never
    /// a real user-facing toggle. Reads the old bare key (`streamingLongDictation`) for
    /// compatibility with existing `defaults write` muscle memory and any machine that already
    /// set it before this flag moved under `FeatureFlags`.
    public static var streamingLongDictation: Bool {
        get {
            #if DEBUG
            guard UserDefaults.standard.object(forKey: streamingLongDictationKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: streamingLongDictationKey)
            #else
            return true
            #endif
        }
        set {
            #if DEBUG
            UserDefaults.standard.set(newValue, forKey: streamingLongDictationKey)
            #endif
        }
    }

    /// Runs post-hoc speaker diarization (`SpeakerDiarizer`) after a note finishes recording —
    /// see docs/research/speaker-labeling.md. Defaults on in all builds per the founder decision
    /// recorded in `.claude/DECISIONS.md` on 2026-09-28. Explicitly setting the stored value to
    /// false remains a kill switch (DEBUG Developer settings; `defaults` override in release).
    /// Diarization is not Pro-gated, and voice-signature enrollment still requires explicit
    /// consent. Read once per note finalize so a toggle takes effect on the next note.
    public static var speakerLabels: Bool {
        get { enabled(speakerLabelsKey) }
        set { UserDefaults.standard.set(newValue, forKey: speakerLabelsKey) }
    }

    /// Learn-from-corrections: whether a learned term becomes active by itself after 2 fixes in
    /// 14 days (`LearningPolicy.autoActivateTerms`), announced by the "Learned from your edits ·
    /// Undo" notice (`LearnedNoticeLine`). On in every build, and `LearningPolicy`'s own default is on. Not a setting the
    /// person is asked to turn on; a stored `false` (the DEBUG Developer pane) is a kill switch that makes learned terms
    /// suggest-only. Read at each capture, so a toggle applies to the next edit.
    public static var autoActivateLearnedTerms: Bool {
        get { enabled(autoActivateLearnedTermsKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoActivateLearnedTermsKey) }
    }

    /// Evidence-based learning (2026-10-28): a learned term is judged on the decayed counts of the times the person changed
    /// it and left it alone (`EvidenceCell`), and applies where those counts support it (`LearnedScope`). On in every build; a
    /// stored `false` is a kill switch that goes back to "two edits in 14 days" and stops counting words left alone.
    public static var evidenceLearning: Bool {
        get { enabled(evidenceLearningKey) }
        set { UserDefaults.standard.set(newValue, forKey: evidenceLearningKey) }
    }

    /// Ask-actions (2026-09-28): the answer card ("what groceries do I need", "ask Claude …",
    /// "summarize this") and act-first with Undo for Tier-1 actions (`ActionPolicy`). Off, the
    /// chord runs only the original Do path and every action shows the confirm card.
    public static var askActions: Bool {
        get { enabled(askActionsKey) }
        set { UserDefaults.standard.set(newValue, forKey: askActionsKey) }
    }

    /// Background AI task hand-off. Off by default, including when no preference exists.
    ///
    /// In a release build this getter always returns `false` and the setter is a no-op, so the
    /// stored key is never read and `defaults write` cannot turn the feature on. Only a DEBUG
    /// build (the Developer settings pane) can. `taskHandoffCanBeTurnedOn` says which this is.
    public static var taskHandoff: Bool {
        get {
            #if DEBUG
            return source.bool(forKey: taskHandoffKey)
            #else
            return false
            #endif
        }
        set {
            #if DEBUG
            source.set(newValue, forKey: taskHandoffKey)
            #endif
        }
    }

    /// Whether this build reads the `taskHandoff` preference at all: true in DEBUG, false in release.
    public static var taskHandoffCanBeTurnedOn: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Meetings and notes (TRY-98, founder 2026-10-28: "keep the meetings private, I do not want to
    /// ship a weak product"): the Notes section, recording a note or a call, the call-detected
    /// prompt, importing a file to transcribe, the Assistant pane (it only reads notes and
    /// meetings), note-saving buttons and every line of copy that mentions them.
    ///
    /// In a release build this getter always returns `false` and the setter is a no-op, so no stored
    /// key, `defaults write` or environment variable can turn it on. A DEBUG build (and so every
    /// test) has it on; `feature.meetings` set to `false`, or `HUSHY_MEETINGS=off` in the
    /// environment, switches it off there to try the release layout (snapshots use the variable).
    /// A meetings preview build (`scripts/build-app.sh --meetings-preview`, an optimized build
    /// compiled with `-DHUSHY_MEETINGS_PREVIEW` for the founder's test) follows the DEBUG rule; the
    /// release script never passes that flag. Saved notes are never touched either way.
    /// `meetingsCanBeTurnedOn` says which build this is.
    public static var meetings: Bool {
        get {
            #if DEBUG || HUSHY_MEETINGS_PREVIEW
            return meetingsEnabled(environment: ProcessInfo.processInfo.environment, stored: source.object(forKey: meetingsKey))
            #else
            return false
            #endif
        }
        set {
            #if DEBUG || HUSHY_MEETINGS_PREVIEW
            source.set(newValue, forKey: meetingsKey)
            #endif
        }
    }

    /// Whether this build reads the `meetings` preference at all: true in DEBUG and in a meetings
    /// preview build, false in release.
    public static var meetingsCanBeTurnedOn: Bool {
        #if DEBUG || HUSHY_MEETINGS_PREVIEW
        return true
        #else
        return false
        #endif
    }

    /// True only in an optimized build made with `--meetings-preview`, so the window can say it is
    /// a preview and nobody mistakes it for the release.
    public static var isMeetingsPreviewBuild: Bool {
        #if HUSHY_MEETINGS_PREVIEW && !DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The DEBUG rule for `meetings`: on, unless the environment says `off` (`0`, `false` and `no`
    /// also count) or a stored `false` does. The environment wins so one render can show the release layout.
    static func meetingsEnabled(environment: [String: String], stored: Any?) -> Bool {
        if let value = environment[meetingsEnvironmentKey]?.lowercased(),
           ["off", "0", "false", "no"].contains(value) { return false }
        return stored as? Bool ?? true
    }

    /// Voice edit (`VoiceEditor`): select text, press the key and say how to change it. Off for
    /// everyone until it is measured in real use: a release build ignores the stored key, as it does
    /// for meetings. On in DEBUG builds and in a test build made with
    /// `HUSHY_TEST_FEATURES=voice-edit scripts/build-app.sh` (Info.plist `HushyTestFeatures`), where a
    /// stored `feature.voiceEdit` of false turns it off.
    public static var voiceEdit: Bool {
        get {
            voiceEditEnabled(stored: source.object(forKey: voiceEditKey),
                             testFeatures: Bundle.main.object(forInfoDictionaryKey: testFeaturesInfoKey) as? String)
        }
        set { source.set(newValue, forKey: voiceEditKey) }
    }

    /// Restyle selection: right-click Services and a shortcut that rewrite or copy the selected text in a tone
    /// (`RestyleController`, `RestyleServicesProvider`). On in every build; a stored `feature.restyleSelection` of
    /// false is the kill switch. It reads the selection only when the person presses the shortcut or picks a
    /// Services item.
    public static var restyleSelection: Bool {
        get { enabled(restyleSelectionKey) }
        set { source.set(newValue, forKey: restyleSelectionKey) }
    }

    static func voiceEditEnabled(stored: Any?, testFeatures: String?, debug: Bool = isDebugBuild) -> Bool {
        let named = testFeatures?.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "voice-edit" } ?? false
        guard debug || named else { return false }
        return stored as? Bool ?? true
    }

    /// Cross-meeting memory: "Ask your meetings", the People and Companies pages and the prep brief
    /// before a call. Hidden for launch (it completes 14 of 44 unseen cases). Off in every build,
    /// debug and preview included. Only an Info.plist `HushyTestFeatures` naming `meeting-ask`
    /// (`HUSHY_TEST_FEATURES=meeting-ask scripts/build-app.sh`) turns it on. Single-meeting notes
    /// never depend on it.
    public static var meetingAsk: Bool {
        meetingAskEnabled(testFeatures: Bundle.main.object(forInfoDictionaryKey: testFeaturesInfoKey) as? String)
    }

    static func meetingAskEnabled(testFeatures: String?) -> Bool {
        testFeatures?.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "meeting-ask" } ?? false
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Optional account and paid-plan UI. Still requires a configured Supabase URL.
    public static var accounts: Bool {
        get { enabled(accountsKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountsKey) }
    }

    /// Where `enabled` reads. The app never changes it; the headless mock-microphone mode points it
    /// at a throwaway suite so a run never reads the user's own defaults.
    nonisolated(unsafe) public static var source: UserDefaults = .standard

    /// Off unless a `true` is stored under `key`: the rule for a flag that ships off.
    static func isExplicitlyOn(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool == true
    }

    /// On unless a `false` is stored under `key`.
    private static func enabled(_ key: String) -> Bool {
        source.object(forKey: key) as? Bool ?? true
    }

    static let taskHandoffKey = "feature.taskHandoff"
    static let pasteGlowKey = "feature.pasteGlow"
    static let personMemoryKey = "feature.personMemory"
    static let accountsKey = "feature.accounts"
    static let installedNamesKey = "feature.installedNames"
    static let screenContextSpellingKey = "feature.screenContextSpelling"
    static let personalLexiconKey = "feature.personalLexicon"
    static let askActionsKey = "feature.askActions"
    static let autoActivateLearnedTermsKey = "feature.autoActivateLearnedTerms"
    static let evidenceLearningKey = "feature.evidenceLearning"
    static let recordingEncryptionKey = "feature.recordingEncryption"
    static let streamingLongDictationKey = "streamingLongDictation"
    static let speakerLabelsKey = "feature.speakerLabels"
    static let meetingAppIntegrationKey = "feature.meetingAppIntegration"
    static let meetingsKey = "feature.meetings"
    static let voiceEditKey = "feature.voiceEdit"
    static let restyleSelectionKey = "feature.restyleSelection"
    static let testFeaturesInfoKey = "HushyTestFeatures"
    static let meetingsEnvironmentKey = "HUSHY_MEETINGS"
}
