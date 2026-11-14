import FluidAudio
import Foundation
import MurmurCore
import Observation
import os
import ServiceManagement

/// User preferences, persisted to UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "triggerKey") } }
    /// Rival dictation apps (`RivalDictationApp.id`) whose shared-key notice the person answered
    /// with "keep my key". Slugs only; the notice does not come back for these.
    var keptSharedKeyWith: Set<String> { didSet { save(keptSharedKeyWith.sorted(), "keptSharedKeyWith") } }
    /// The key pressed twice to start a voice action (Control by default). Holding fn + control
    /// keeps working whatever this is.
    var actionTrigger: ActionTriggerKey { didSet { save(actionTrigger.rawValue, "actionTriggerKey") } }
    /// The chord that opens the restyle chips over the selected text (⌃⌘T by default, or off).
    var restyleShortcut: RestyleShortcut { didSet { save(restyleShortcut.rawValue, "restyleShortcut") } }
    /// The key voice actions really use: the choice, unless it is also the dictation key.
    var effectiveActionTrigger: ActionTriggerKey { .effective(actionTrigger, dictation: triggerKey) }
    /// The default tone, the per-destination tones and "As spoken" (Voice & style, the menu bar,
    /// onboarding). One value, stored as one JSON blob, so a change is never half saved.
    /// Earlier versions' `cleanupLevel` and `styles` keys are read once to set this and then left
    /// alone, so an older build opened on the same data still finds them.
    var toneSettings: ToneSettings {
        didSet {
            if toneSettings.choice != oldValue.choice {
                // Kept in the log beside "tone row clicked": the option's name only.
                Self.log.notice("tone choice stored: \(self.toneSettings.choice.rawValue, privacy: .public)")
            }
            guard let data = try? JSONEncoder().encode(toneSettings) else { return }
            defaults.set(data, forKey: Self.toneSettingsKey)
        }
    }
    static let toneSettingsKey = "toneSettings"
    private static let log = Logger(subsystem: "app.hushy", category: "settings")
    /// The cleanup level for a dictation: "As spoken", or the cleanup every tone is built on.
    var dictationLevel: CleanupLevel { toneSettings.dictationLevel }
    /// The cleanup level for notes and imported files, which are never given a tone.
    var noteCleanupLevel: CleanupLevel { toneSettings.noteCleanupLevel }
    /// "Cleanup model" in Settings → Writing: Apple Intelligence (default), the downloaded Hushy
    /// local model (experimental), or rules only. See `CleanupModelController`.
    var cleanupBackend: CleanupBackendChoice { didSet { save(cleanupBackend.rawValue, "cleanupBackend") } }
    /// The local model the user picked over the RAM-tier recommendation; nil = recommended.
    var localCleanupModelID: String? { didSet { save(localCleanupModelID ?? "", "localCleanupModelID") } }
    /// Hidden: forces the 4B on eligible Macs (24 GB+, Pro/Max), even over an explicit model choice. The 4B is also the
    /// default there now (2026-10-27), so this only matters after a different model was picked. No UI toggle.
    var useIntentCleanup4B: Bool { didSet { save(useIntentCleanup4B, "useIntentCleanup4B") } }
    /// Hidden: the way back to the 2B intent model on a Mac that would get the 4B by default.
    var preferIntentCleanup2B: Bool { didSet { save(preferIntentCleanup2B, "preferIntentCleanup2B") } }
    var voiceCommands: Bool { didSet { save(voiceCommands, "voiceCommands") } }
    /// "Use American spelling" on Voice & style → Style. Rewrites British spellings the recognizer
    /// emits ("colour" -> "color") to American ones; see `AmericanSpelling` and
    /// `CleanupOptions.americanSpelling`. Default ON when the system locale's region is the US,
    /// OFF otherwise (see `init`'s one-time default below) — see docs/product/US-ENGLISH-ACCURACY.md
    /// §5 for the measurement behind this default, and .claude/DECISIONS.md for the rationale.
    /// Once the user has an explicit stored value it always wins, including if they later move
    /// the system region.
    var americanSpelling: Bool { didSet { save(americanSpelling, "americanSpelling") } }
    /// "Keep dictations on the clipboard" in Settings → Advanced. Default OFF (founder decision
    /// 2026-10-09, reversing the 2026-09-28 default): text that was typed into a window must not
    /// take over the clipboard, so the previous clipboard comes back after the paste. ON: the
    /// dictation stays (marked transient so clipboard-history managers skip it). Never for
    /// password-field or cancelled dictations. See `ClipboardPaster.keepsPastedText`.
    var keepDictationsOnClipboard: Bool { didSet { save(keepDictationsOnClipboard, "keepDictationsOnClipboard") } }
    /// "Notes and meetings (preview)" in Settings → Advanced. Notes and meetings are frozen, so the
    /// settings that belong only to them (the Notes & meetings pane with its Voices list, and the
    /// Assistant chat) stay out of Settings until this is on. Turning it off hides them again and
    /// changes nothing they stored. Default OFF.
    var notesAndMeetingsPreview: Bool { didSet { save(notesAndMeetingsPreview, "notesAndMeetingsPreview") } }
    var soundsEnabled: Bool { didSet { save(soundsEnabled, "soundsEnabled") } }
    var showIdlePill: Bool { didSet { save(showIdlePill, "showIdlePill") } }
    /// The Large pill: the live words run beside the bars while you talk. Off is Mini, the default
    /// (2026-10-28, founder): bars only. The live draft passes run either way, because cleanup uses
    /// them (`DictationController.liveDraft`); only the drawing stops. See `PillPresence`.
    var pillShowsLiveWords: Bool { didSet { save(pillShowsLiveWords, "pillShowsLiveWords") } }
    /// Hide the resting pill while a video plays or the front app is full screen (Settings → General).
    var hideIdlePillDuringVideoOrFullScreen: Bool {
        didSet { save(hideIdlePillDuringVideoOrFullScreen, "hideIdlePillDuringVideoOrFullScreen") }
    }
    /// The Home tips the person closed (`HomeTip.rawValue`); each shows once until then.
    var dismissedHomeTips: Set<String> { didSet { save(dismissedHomeTips.sorted(), "dismissedHomeTips") } }
    /// nil keeps audio forever, 0 keeps none.
    var audioRetentionDays: Int? { didSet { save(audioRetentionDays ?? -1, "audioRetentionDays") } }
    /// How long dictation text is kept (nil = forever). Default 30 days; notes are never expired.
    var textRetentionDays: Int? { didSet { save(textRetentionDays ?? -1, "textRetentionDays") } }
    var inputDeviceName: String? { didSet { save(inputDeviceName ?? "", "inputDeviceName") } }
    var exportNotesToMarkdown: Bool { didSet { save(exportNotesToMarkdown, "exportNotesToMarkdown") } }
    var exportDirectory: URL { didSet { save(exportDirectory.path, "exportDirectory") } }
    var saveNotesToAppleNotes: Bool { didSet { save(saveNotesToAppleNotes, "saveNotesToAppleNotes") } }
    /// Voice actions: "Ask before doing" — Always / Only for risky actions (default) / Never.
    /// The one policy (`ActionPolicy`) reads it per utterance; "Never" still keeps drafts as drafts, and Shortcuts and agent actions still ask first.
    var askBeforeDoing: ActionPolicy.AskBeforeDoing { didSet { save(askBeforeDoing.rawValue, "askBeforeDoing") } }
    /// "Ask about your own stuff" may search Apple Notes (needs the Automation permission, asked
    /// when this turns on). Off by default: Hushy's notes, history, Reminders and Calendar only.
    var searchAppleNotes: Bool { didSet { save(searchAppleNotes, "searchAppleNotes") } }
    /// "Record call audio" — capture system/output audio (the other side of a call) alongside
    /// the mic while recording a note. See `.claude/DECISIONS.md`'s system-audio entry. Defaults
    /// ON once permission has been granted at least once (see `init`'s one-time default below);
    /// starting a note still checks live permission/entitlement state every time via
    /// `NoteRecorder.start()`, so turning this on here is necessary but not sufficient.
    var recordCallAudio: Bool { didSet { save(recordCallAudio, "recordCallAudio") } }
    /// "Ask to record when a call starts" (Settings → Notes/Meetings). See `CallDetectionState`
    /// and `CallDetector`. Default ON: a meeting app being detected is itself evidence the user
    /// might want notes, and the prompt is easy to dismiss/never-show-again per app.
    var askToRecordCalls: Bool { didSet { save(askToRecordCalls, "askToRecordCalls") } }
    /// "Name notes from your calendar" (Settings → Meetings): a note started during a calendar
    /// meeting is titled after it. Until the user chooses, it follows whether calendar access was
    /// already granted (for example through voice actions); turning it on in Settings is what asks
    /// macOS for access, never launch or starting a recording. See `NoteCalendarNamer`.
    var nameNotesFromCalendar: Bool { didSet { save(nameNotesFromCalendar, "nameNotesFromCalendar") } }
    /// Apps the user chose "Never for <App>" for — never prompted again. Stored as raw
    /// `MeetingApp` values (small closed set) rather than an opaque blob so a `defaults read` is
    /// legible, matching the plain-scalar style of every other setting here.
    var neverAskForApps: Set<MeetingApp> {
        didSet { save(neverAskForApps.map(\.rawValue), "neverAskForApps") }
    }
    /// Maximum length for a note recording (manual or call-detected). Default 2 hours per the
    /// task's contract; a warning shows 2 minutes before the limit (`CallDetectionState.maxLengthWarning`).
    var maxRecordingLength: MaxRecordingLength { didSet { save(maxRecordingLength.rawValue, "maxRecordingLength") } }
    var reduceBackgroundNoise: Bool { didSet { save(reduceBackgroundNoise, "reduceBackgroundNoise") } }
    /// "Encrypt data on this Mac" in Settings → Privacy & data. The source of truth for whether
    /// audio files on disk are encrypted; `EncryptionController` is what actually runs the
    /// migration when this flips, and keeps this in sync afterward.
    var encryptDataAtRest: Bool { didSet { save(encryptDataAtRest, "encryptDataAtRest") } }
    /// "Require Touch ID to open History & Notes" in Settings → Privacy & data.
    var appLockEnabled: Bool { didSet { save(appLockEnabled, "appLockEnabled") } }
    /// "Context awareness" in Settings → Privacy & data. On by default (see
    /// `.claude/DECISIONS.md`): when on, `DictationController` reads up to ±1,000 characters
    /// around the insertion point via the Accessibility API at the start of each dictation,
    /// derives temporary boost terms/spelling fixes for that one dictation, and discards them
    /// immediately after — nothing captured is logged or persisted. See `ContextExtractor`/
    /// `ContextSpellingFixer` in MurmurCore for the pure extraction/fix logic.
    var contextAwarenessEnabled: Bool { didSet { save(contextAwarenessEnabled, "contextAwarenessEnabled") } }
    /// "Learn from my edits" (on by default; see `.claude/DECISIONS.md`, 2026-09-27): after a
    /// paste, `EditWatcher` compares the field a few seconds later with what was inserted and
    /// stores only short derived corrections ("Pria" → "Priya") as `LearnedItem`s. Never in
    /// secure fields, password managers, code editors, or apps in `learningExcludedApps`.
    var learnFromEdits: Bool { didSet { save(learnFromEdits, "learnFromEdits") } }
    /// Bundle IDs the user excluded from learning ("Don't learn in this app").
    var learningExcludedApps: Set<String> {
        didSet { save(learningExcludedApps.sorted(), "learningExcludedApps") }
    }
    /// How long Memory keeps the changes the person made to their dictations. `never` unless
    /// they choose otherwise (there is no control for it yet): what Hushy keeps does not expire
    /// by itself.
    var memoryEditLife: MemoryLife { didSet { save(memoryEditLife.rawValue, "memoryEditLife") } }
    /// Minutes of inactivity before auto-lock (only meaningful when `appLockEnabled`). Default 5.
    var appLockAutoLockMinutes: Int { didSet { save(appLockAutoLockMinutes, "appLockAutoLockMinutes") } }
    /// English-only (Parakeet Ultra + the v2 drift guard) vs Automatic/25 languages (Ultra,
    /// no guard). Default is English-only; see .claude/DECISIONS.md (2026-09-26, "English
    /// default moves to Ultra with a drift guard") for why the model behind it changed from v2.
    var speechLanguageMode: SpeechLanguageMode { didSet { save(speechLanguageMode.rawValue, "speechLanguageMode") } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    var sidebarCollapsed: Bool { didSet { save(sidebarCollapsed, "sidebarCollapsed") } }
    /// When History was last on screen — the History badge counts only actionable dictations
    /// newer than this (see `HistoryAttention`). First read on an install that never stored it
    /// starts at "now", so an upgrade doesn't greet the user with a backlog they already saw.
    var historySeenAt: Date { didSet { save(historySeenAt.timeIntervalSince1970, "historySeenAt") } }
    /// Home's right-hand Assistant column (action items + chat) folded away (⌘⌥0). Default
    /// expanded: the column is where open action items and the chat live.
    var assistantCollapsed: Bool { didSet { save(assistantCollapsed, "assistantCollapsed") } }
    /// The Assistant column's "Open action items" section folded to its header.
    var assistantActionItemsCollapsed: Bool {
        didSet { save(assistantActionItemsCollapsed, "assistantActionItemsCollapsed") }
    }
    /// The Assistant chat (asking your own Claude Code about your history). OFF by default: it's
    /// the one feature that sends Hushy data off the Mac, so it's opt-in behind a consent sheet
    /// (see `.claude/DECISIONS.md`). Turning it off stops any running request.
    var assistantEnabled: Bool { didSet { save(assistantEnabled, "assistantEnabled") } }
    /// The version of the Assistant consent text the user agreed to (0 = never). Bump
    /// `AssistantConsent.currentVersion` when the wording changes materially, and the sheet
    /// shows again the next time the Assistant is turned on.
    var assistantConsentVersion: Int { didSet { save(assistantConsentVersion, "assistantConsentVersion") } }
    /// Which Claude model the Assistant uses. Default Haiku (fastest).
    var assistantModel: AssistantModelChoice { didSet { save(assistantModel.rawValue, "assistantModel") } }
    /// Custom modes: the 5 built-ins (Default, Email, Message, Note, Bullet points) plus
    /// anything the user creates/duplicates in Voice & style → Modes. Stored as one JSON array
    /// under `UserDefaults` key `"modes"` — the simplest persistence that supports create/edit/
    /// duplicate/delete without a migration, matching every other list-shaped setting in this
    /// file (`styles`) rather than introducing SQLite storage for what is, at most, a few dozen
    /// small structs. See docs/guide/HUSHY_GUIDE.md "Modes" for the documented JSON shape.
    var modes: [Mode] {
        didSet {
            guard let data = try? Self.modesEncoder.encode(modes) else { return }
            defaults.set(data, forKey: "modes")
        }
    }
    /// Manual mode override for the *next* dictation only (picked from the pill's mode chip).
    /// Not persisted across launches — a one-shot, like a modifier key held down. `nil` means
    /// "use per-app assignment, falling back to Default" (see `ModeResolver`).
    var manualModeOverrideID: UUID?

    /// The mode `ModeResolver` should use right now for a given focused app, given the current
    /// manual override (if any). Consumes and clears the manual override so it applies to
    /// exactly one dictation, matching the pill mode chip's "pick a mode for what I'm about to
    /// say" behavior.
    ///
    /// The stock Default mode takes the level of the app (or, in a browser, the placed website) it is resolved for:
    /// word for word when that app or site sits in As spoken (`ToneSettings.dictationLevel(for:site:)`). A mode
    /// picked for this one dictation, or one assigned to the app, keeps its own level.
    func consumeActiveMode(bundleID: String?, site: String? = nil) -> Mode {
        let mode = previewActiveMode(bundleID: bundleID, site: site)
        manualModeOverrideID = nil
        return mode
    }

    /// Read-only peek at what `consumeActiveMode` would currently return, without consuming the
    /// manual override — used by the pill's mode chip to show which mode is about to apply.
    func previewActiveMode(bundleID: String?, site: String? = nil) -> Mode {
        let override = manualModeOverrideID.flatMap { id in modes.first { $0.id == id } }
        let fallback = modes.first { $0.id == Mode.BuiltInID.default } ?? Mode.builtIns(userName: userName)[0]
        return ModeResolver.resolve(manualOverride: override, bundleID: bundleID, modes: modes, defaultMode: fallback)
            .resolvingAppCleanupLevel(toneSettings.dictationLevel(for: bundleID, site: site))
    }

    /// A mode can be deleted only if it is not a built-in; deleting the mode currently referenced
    /// by any app assignment just leaves those assignments pointing at a mode ID that no longer
    /// exists, which `ModeResolver` treats the same as "no assignment" (falls through to
    /// Default) since `first(where:)` simply finds nothing.
    func deleteMode(id: UUID) {
        modes.removeAll { $0.id == id && !$0.isBuiltIn }
        if manualModeOverrideID == id { manualModeOverrideID = nil }
    }

    /// Adds a new mode or replaces an existing one with the same `id`.
    func upsertMode(_ mode: Mode) {
        if let index = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[index] = mode
        } else {
            modes.append(mode)
        }
    }

    /// A non-built-in copy of `mode`, appended to `modes`— "Email copy", "Email copy 2", etc.
    @discardableResult
    func duplicateMode(_ mode: Mode) -> Mode {
        let baseName = mode.name + " copy"
        var name = baseName
        var suffix = 2
        while modes.contains(where: { $0.name == name }) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        let copy = Mode(name: name, icon: mode.icon, cleanupLevel: mode.cleanupLevel,
                         prompt: mode.prompt, appBundleIDs: [], isBuiltIn: false)
        modes.append(copy)
        return copy
    }

    private static let modesEncoder = JSONEncoder()
    private static let modesDecoder = JSONDecoder()

    enum SpeechLanguageMode: String, CaseIterable, Identifiable {
        case englishOnly, automatic

        var id: String { rawValue }
        var title: String {
            switch self {
            case .englishOnly: "English only"
            case .automatic: "Automatic (25 languages)"
            }
        }

        /// Both modes run Parakeet Ultra (the v3 family): it is 2.5–2.9 WER points better than
        /// v2 on spontaneous speech (docs/research/accent-robustness.md). What differs is the
        /// drift guard below. Existing users keep whichever mode they chose; only the model
        /// behind "English only" changed (2026-09-26, .claude/DECISIONS.md).
        var modelVersion: AsrModelVersion {
            switch self {
            case .englishOnly, .automatic: .ultra
            }
        }

        /// English-only re-transcribes with Parakeet v2 whenever Ultra's output is not English
        /// (`AsrDriftGuard` / `SpeechEngine`). Automatic wants other languages kept, so no guard.
        var driftGuardEnabled: Bool { self == .englishOnly }

        /// Settings → General → "Language". Says what English only does when speech
        /// is misheard as another language (the drift guard above) without naming models.
        static let settingsDetail =
            "English only is most accurate for English and corrects itself if it mishears another language. Automatic handles other languages."

        /// Shown next to the Settings → Dictation "Speech model" row so switching modes tells
        /// the user what they're about to download, without naming the model itself (release UI
        /// never shows engine/model names — see `AsrModelVersion.settingsLabel`). Sizes are
        /// the on-disk Core ML caches (Ultra 603 MB, v2 443 MB, measured 2026-09-26); both modes
        /// share the Ultra download, so switching modes never re-downloads. On Macs above the
        /// 8 GB small-memory tier, English-only preloads v2 after Ultra is ready.
        var downloadDetail: String {
            switch self {
            case .englishOnly:
                "About 600 MB, downloaded once. Macs with more than 8 GB of memory also download a second, 450 MB English model in the background, used for that second check."
            case .automatic:
                "About 600 MB, downloaded once, for 25-language coverage."
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }
    }

    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    /// Local-only first-run funnel (gate 11): when onboarding started, the model became ready,
    /// each permission was granted, and the first dictation pasted. Never leaves the Mac; shown
    /// in Settings → Developer (DEBUG builds). See `OnboardingFunnelRecorder`.
    var onboardingFunnel: OnboardingFunnel {
        didSet {
            guard let data = try? Self.calibrationEncoder.encode(onboardingFunnel) else { return }
            defaults.set(data, forKey: "onboardingFunnel")
        }
    }
    /// "Share usage numbers" in Settings → Privacy & security and on the welcome screen. Off until
    /// the person turns it on (founder decision, 2026-10-11, replacing on-by-default of 2026-10-06):
    /// a stored choice is kept, and no stored choice means off. A daily batch of counts and timings,
    /// never words, audio, names or any identifier. Turning it off stops recording at once and
    /// deletes the local queue. See `UsageMetricsRecorder` and the handbook's telemetry stance.
    var shareUsageNumbers: Bool {
        didSet {
            closeUsageGate()                       // first, in memory: off, and the epoch goes up
            persistUsageEpoch()                    // then the epoch, and the switch next to it
            save(shareUsageNumbers, "shareUsageNumbers")
            openUsageGateIfConfirmed()             // on only once both are saved
            if oldValue != shareUsageNumbers { onUsageSwitchChange?(shareUsageNumbers) }
        }
    }
    static let currentCrashConsentVersion = 1
    /// Crash reports require a separate, versioned choice. A changed disclosure turns sharing off.
    var shareCrashReports: Bool {
        didSet {
            save(shareCrashReports, "shareCrashReports")
            if oldValue != shareCrashReports { onCrashSwitchChange?(shareCrashReports) }
        }
    }
    var crashConsentVersion: Int { didSet { save(crashConsentVersion, "crashConsentVersion") } }
    @ObservationIgnored var onCrashSwitchChange: ((Bool) -> Void)?
    /// True once the person has been shown the switch and its sentence and has answered: pressing
    /// "Get started" on the welcome screen, pressing OK on Home's one-time notice, or closing the
    /// "See what's sent" sheet. Opening the sheet is not enough: the gate stays off while it is
    /// open. Nothing is recorded before it.
    var usageNumbersNoticeSeen: Bool {
        didSet {
            closeUsageGate()
            persistUsageEpoch()
            save(usageNumbersNoticeSeen, "usageNumbersNoticeSeen")
            openUsageGateIfConfirmed()
            if !oldValue, usageNumbersNoticeSeen { onUsageNoticeSeen?() }
        }
    }
    var isSharingUsageNumbers: Bool { shareUsageNumbers && usageNumbersNoticeSeen }
    /// "Send a daily count" in Settings → Privacy & security. **On by default**, for new and existing
    /// installs (founder, 2026-10-28: "we need all sort of data"): once a UTC day Hushy tells the site this Mac
    /// used it, as `{"v":2,"build":…,"first":…}` with no identifier of any kind (`DailyCountSender`). A switch
    /// of its own, separate from usage numbers: the usage batch stays off until the person turns it on, and
    /// this one does not need that notice. A stored choice is kept; no stored choice means on.
    var sendDailyCount: Bool {
        didSet {
            save(sendDailyCount, "sendDailyCount")
            dailyCountGate.isOn = sendDailyCount
        }
    }
    /// The thread-safe copy of `sendDailyCount` that `DailyCountSender` reads. Turning it off cancels a
    /// request in flight.
    @ObservationIgnored let dailyCountGate = MetricsSwitch()
    /// The thread-safe copy of `isSharingUsageNumbers` the recording and uploading code reads. It
    /// is flipped inside the setters above, in the same call that changes the setting.
    @ObservationIgnored let usageGate = MetricsSwitch()
    /// True when the data epoch could not be saved and read back. Usage numbers then stay off
    /// (fail closed) and Settings says so in one line; the next change of the switch tries again.
    var usageStorageFault = false
    /// Called right after the switch changes (set by `UsageMetricsRecorder`; queues the deletion).
    @ObservationIgnored var onUsageSwitchChange: ((Bool) -> Void)?
    @ObservationIgnored var onUsageNoticeSeen: (() -> Void)?
    /// The day this Mac first ran Hushy (this build, for an install that predates it), kept only
    /// to band "days since first run" in the usage numbers. Never sent as a date.
    let firstRunAt: Date
    var userName: String { didSet { save(userName, "userName") } }
    /// Measured by the typing test (Insights). nil until measured; "time saved" then assumes
    /// an average typist (`Insights.typingWPM`).
    var typingWPM: Double? { didSet { save(typingWPM ?? -1, "typingWPM") } }
    var effectiveTypingWPM: Double { typingWPM ?? Insights.typingWPM }
    /// Set by "Tune Hushy to your voice" (onboarding step + Settings → re-runnable). nil until
    /// the user completes a Tune session at least once.
    var voiceCalibration: VoiceCalibration? {
        didSet {
            guard let data = try? voiceCalibration.map(Self.calibrationEncoder.encode) else {
                defaults.removeObject(forKey: "voiceCalibration")
                return
            }
            defaults.set(data, forKey: "voiceCalibration")
        }
    }

    private static let calibrationEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let calibrationDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(defaults: UserDefaults = .standard, systemRegion: Locale.Region? = Locale.current.region,
         machine: MachineProfile = .current(),
         calendarAuthorization: CalendarAuthorization = EventKitCalendarReader.currentAuthorization()) {
        self.defaults = defaults
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: "triggerKey") ?? "") ?? .fn
        keptSharedKeyWith = Set(defaults.stringArray(forKey: "keptSharedKeyWith") ?? [])
        actionTrigger = ActionTriggerKey(rawValue: defaults.string(forKey: "actionTriggerKey") ?? "") ?? .default
        restyleShortcut = RestyleShortcut(rawValue: defaults.string(forKey: "restyleShortcut") ?? "") ?? .default
        toneSettings = Self.loadToneSettings(defaults)
        cleanupBackend = CleanupBackendChoice(rawValue: defaults.string(forKey: "cleanupBackend") ?? "")
            ?? (ModelTierPolicy.promotedEntry(for: machine) == nil ? .apple : .local)
        let storedModelID = defaults.string(forKey: "localCleanupModelID") ?? ""
        localCleanupModelID = ModelRegistry.entry(id: storedModelID) == nil ? nil : storedModelID
        useIntentCleanup4B = defaults.bool(forKey: "useIntentCleanup4B")
        preferIntentCleanup2B = defaults.bool(forKey: "preferIntentCleanup2B")
        voiceCommands = defaults.object(forKey: "voiceCommands") as? Bool ?? true
        keepDictationsOnClipboard = defaults.object(forKey: "keepDictationsOnClipboard") as? Bool ?? false
        notesAndMeetingsPreview = defaults.object(forKey: "notesAndMeetingsPreview") as? Bool ?? false
        // Default ON for a US system region, OFF otherwise; the user's own explicit choice (once
        // saved) always overrides this. `systemRegion` defaults to the live system locale and is
        // injectable so tests can pin it. See docs/product/US-ENGLISH-ACCURACY.md §5.
        americanSpelling = defaults.object(forKey: "americanSpelling") as? Bool ?? (systemRegion?.identifier == "US")
        // Start/stop ticks are off by default (owner feedback: no blips); reset the old default once.
        if !defaults.bool(forKey: "soundsDefaultOffV2") {
            defaults.set(false, forKey: "soundsEnabled")
            defaults.set(true, forKey: "soundsDefaultOffV2")
        }
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? false
        showIdlePill = defaults.object(forKey: "showIdlePill") as? Bool ?? true
        pillShowsLiveWords = defaults.object(forKey: "pillShowsLiveWords") as? Bool ?? false
        hideIdlePillDuringVideoOrFullScreen = defaults.object(forKey: "hideIdlePillDuringVideoOrFullScreen") as? Bool ?? true
        dismissedHomeTips = Set(defaults.array(forKey: "dismissedHomeTips") as? [String] ?? [])
        let retention = defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
        audioRetentionDays = retention < 0 ? nil : retention
        let textRetention = defaults.object(forKey: "textRetentionDays") as? Int ?? 30
        textRetentionDays = textRetention < 0 ? nil : textRetention
        let device = defaults.string(forKey: "inputDeviceName") ?? ""
        inputDeviceName = device.isEmpty ? nil : device
        exportNotesToMarkdown = defaults.object(forKey: "exportNotesToMarkdown") as? Bool ?? true
        exportDirectory = defaults.string(forKey: "exportDirectory").map { URL(fileURLWithPath: $0) }
            ?? AppPaths.defaultExportDirectory
        saveNotesToAppleNotes = defaults.bool(forKey: "saveNotesToAppleNotes")
        askBeforeDoing = defaults.string(forKey: "askBeforeDoing").flatMap(ActionPolicy.AskBeforeDoing.init(rawValue:)) ?? .risky
        searchAppleNotes = defaults.bool(forKey: "searchAppleNotes")
        // Default ON, per the task's contract ("default ON once permission is granted") — this
        // is the *setting's* default, not a live permission check; `NoteRecorder.start()` still
        // checks `SystemAudioCapture.permissionState()`/`Entitlements` every time before actually
        // capturing, so leaving this true when permission hasn't been granted yet is harmless
        // (capture simply doesn't start, and Settings/the pill explain why via
        // `SystemAudioPermissionState.userMessage`).
        recordCallAudio = defaults.object(forKey: "recordCallAudio") as? Bool ?? true
        askToRecordCalls = defaults.object(forKey: "askToRecordCalls") as? Bool ?? true
        nameNotesFromCalendar = defaults.object(forKey: "nameNotesFromCalendar") as? Bool ?? calendarAuthorization.canRead
        let neverRaw = defaults.array(forKey: "neverAskForApps") as? [String] ?? []
        neverAskForApps = Set(neverRaw.compactMap(MeetingApp.init(rawValue:)))
        maxRecordingLength = MaxRecordingLength(rawValue: defaults.string(forKey: "maxRecordingLength") ?? "")
            ?? .default
        // Voice processing measurably hurt accuracy on real recordings (whispers: 0% WER off vs
        // 27–33% on; see DECISIONS.md), so it is off by default. Earlier builds defaulted it on;
        // reset that default once, after which the user's own choice sticks.
        if !defaults.bool(forKey: "reduceBackgroundNoiseDefaultV2") {
            defaults.set(false, forKey: "reduceBackgroundNoise")
            defaults.set(true, forKey: "reduceBackgroundNoiseDefaultV2")
        }
        reduceBackgroundNoise = defaults.object(forKey: "reduceBackgroundNoise") as? Bool ?? false
        encryptDataAtRest = defaults.bool(forKey: "encryptDataAtRest")
        appLockEnabled = defaults.bool(forKey: "appLockEnabled")
        contextAwarenessEnabled = defaults.object(forKey: "contextAwarenessEnabled") as? Bool ?? true
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        learningExcludedApps = Set(defaults.array(forKey: "learningExcludedApps") as? [String] ?? [])
        memoryEditLife = MemoryLife(rawValue: defaults.integer(forKey: "memoryEditLife")) ?? .never
        appLockAutoLockMinutes = defaults.object(forKey: "appLockAutoLockMinutes") as? Int ?? 5
        speechLanguageMode = SpeechLanguageMode(rawValue: defaults.string(forKey: "speechLanguageMode") ?? "") ?? .englishOnly
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        sidebarCollapsed = defaults.bool(forKey: "sidebarCollapsed")
        let storedSeen = defaults.object(forKey: "historySeenAt") as? Double
        let seenAt = storedSeen.map(Date.init(timeIntervalSince1970:)) ?? Date()
        if storedSeen == nil { defaults.set(seenAt.timeIntervalSince1970, forKey: "historySeenAt") }
        historySeenAt = seenAt
        assistantCollapsed = defaults.bool(forKey: "assistantCollapsed")
        assistantActionItemsCollapsed = defaults.bool(forKey: "assistantActionItemsCollapsed")
        assistantEnabled = defaults.bool(forKey: "assistantEnabled")
        assistantConsentVersion = defaults.integer(forKey: "assistantConsentVersion")
        assistantModel = AssistantModelChoice(rawValue: defaults.string(forKey: "assistantModel") ?? "") ?? .haiku
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        let storedFunnel = defaults.data(forKey: "onboardingFunnel")
            .flatMap { try? Self.calibrationDecoder.decode(OnboardingFunnel.self, from: $0) } ?? .empty
        onboardingFunnel = storedFunnel
        shareUsageNumbers = defaults.object(forKey: "shareUsageNumbers") as? Bool ?? false
        sendDailyCount = defaults.object(forKey: "sendDailyCount") as? Bool ?? true
        let storedCrashConsent = defaults.integer(forKey: "crashConsentVersion")
        crashConsentVersion = storedCrashConsent
        shareCrashReports = defaults.bool(forKey: "shareCrashReports") && storedCrashConsent == Self.currentCrashConsentVersion
        usageNumbersNoticeSeen = defaults.bool(forKey: "usageNumbersNoticeSeen")
        let storedFirstRun = defaults.object(forKey: "firstRunAt") as? Double
        firstRunAt = storedFirstRun.map(Date.init(timeIntervalSince1970:)) ?? storedFunnel[.onboardingStarted] ?? Date()
        if storedFirstRun == nil { defaults.set(firstRunAt.timeIntervalSince1970, forKey: "firstRunAt") }
        let storedWPM = defaults.object(forKey: "typingWPM") as? Double ?? -1
        typingWPM = storedWPM > 0 ? storedWPM : nil
        let resolvedUserName = defaults.string(forKey: "userName") ?? NSFullUserName().components(separatedBy: " ").first ?? ""
        userName = resolvedUserName
        voiceCalibration = defaults.data(forKey: "voiceCalibration").flatMap { try? Self.calibrationDecoder.decode(VoiceCalibration.self, from: $0) }
        manualModeOverrideID = nil

        let storedModes = defaults.data(forKey: "modes").flatMap { try? Self.modesDecoder.decode([Mode].self, from: $0) } ?? []
        let builtIns = Mode.builtIns(userName: resolvedUserName)
        // Merge: keep every stored mode (built-in, possibly user-edited, or custom) and append
        // any built-in the user's stored set doesn't have yet — covers first launch (empty
        // stored set: the merge is just the built-ins) and a future built-in added after this
        // user already has modes saved, without ever duplicating or resetting an edited one.
        let storedIDs = Set(storedModes.map(\.id))
        modes = storedModes + builtIns.filter { !storedIDs.contains($0.id) }
        // The data epoch (see `MetricsSwitch`) is stored next to the switch itself. A launch with the
        // switch off starts a new epoch, so whatever an earlier run left behind is unreachable even if
        // the process died between turning the switch off and saving the epoch.
        usageEpochWasStored = defaults.object(forKey: Self.usageEpochKey) != nil
        usageGate.restoreEpoch(defaults.integer(forKey: Self.usageEpochKey))
        if !shareUsageNumbers { usageGate.advanceEpoch() }
        persistUsageEpoch()
        openUsageGateIfConfirmed()
        dailyCountGate.isOn = sendDailyCount
    }

    private static let usageEpochKey = "usageDataEpoch"

    /// Whether an epoch was saved before this launch. False after a fresh install or after the
    /// defaults were reset or restored, when whatever is on disk cannot be trusted to belong to it.
    @ObservationIgnored private(set) var usageEpochWasStored = false

    /// Step 1 of every change: if sharing is no longer wanted, turn the thread-safe gate off now, in
    /// memory, before anything is written. That bumps the data epoch and cancels any request in flight.
    private func closeUsageGate() {
        if usageGate.isOn, !isSharingUsageNumbers { usageGate.isOn = false }
    }

    /// Step 2: write the epoch next to the switch and read it back. False means it could not be confirmed.
    @discardableResult
    private func persistUsageEpoch() -> Bool {
        let epoch = usageGate.epoch
        defaults.set(epoch, forKey: Self.usageEpochKey)
        let confirmed = defaults.integer(forKey: Self.usageEpochKey) == epoch
        usageStorageFault = !confirmed
        return confirmed
    }

    /// Step 3: sharing is allowed only after the switch and the epoch are saved together.
    private func openUsageGateIfConfirmed() {
        usageGate.isOn = isSharingUsageNumbers && !usageStorageFault
    }

    /// Called once by the recorder with the highest epoch folder found on disk (nil when none). If
    /// no epoch was saved, or the saved one is lower than a folder that exists, where those folders
    /// came from is unknown (defaults reset or restored): start above all of them. The recorder
    /// then deletes them before anything can be recorded.
    func reconcileUsageEpoch(highestFolder: Int?) {
        guard let highest = highestFolder, !usageEpochWasStored || highest > usageGate.epoch else { return }
        closeUsageGate()
        usageGate.restoreEpoch(highest + 1)
        persistUsageEpoch()
        openUsageGateIfConfirmed()
    }

    var cleanupOptions: CleanupOptions {
        CleanupOptions(level: dictationLevel, voiceCommandsEnabled: voiceCommands, americanSpelling: americanSpelling)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Hushy: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
