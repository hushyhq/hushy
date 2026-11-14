import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The two always-on shortcuts (paste last ⌃⌘V, copy last ⌃⌘C) while the app lock is on: they
/// hand over nothing, the pill says why in one line, and nothing on a recovery row names a
/// shortcut that would refuse. One rule decides all of it: `LockedCopy.canUseLastTranscript`.
///
/// Only the locked path runs through the controller here. It returns before the clipboard, the
/// focused field or the store are touched, so nothing can reach a person's Mac: an in-memory
/// store and key store, a throwaway defaults suite, no sound, no event tap, no model.
@Suite("App lock: paste last and copy last", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AppLockShortcutTests {
    @MainActor
    final class Harness {
        let pill = PillModel()
        let store: Store
        let controller: DictationController
        private let suite = "hushy-test-lock-shortcuts-\(UUID().uuidString)"

        init(isLocked: Bool) throws {
            store = try Store()
            let defaults = try #require(UserDefaults(suiteName: suite))
            let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
            settings.audioRetentionDays = 0
            let sounds = Sounds()
            sounds.isEnabled = false
            let status = SpeechModelStatus()
            let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
            controller = DictationController(
                speech: SpeechEngine(status: status, integrity: integrity), modelStatus: status, store: store,
                settings: settings, pill: pill, sounds: sounds, hotkeys: HotkeyMonitor(),
                encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())),
                cleanupModel: NullLanguageModel(), isAppLocked: { isLocked })
            _ = try store.save(Dictation(
                id: nil, createdAt: Date(), rawText: "the ferry leaves at nine", text: "The ferry leaves at nine.",
                appBundleID: "com.apple.mail", appName: "Mail", durationSeconds: 3, status: .inserted))
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    // MARK: The rule

    @Test("locked, each shortcut refuses with its own line; unlocked, neither does")
    func refusal() {
        #expect(LastTranscriptShortcut.paste.refusal(isLocked: true) == "Unlock Hushy to paste your last dictation")
        #expect(LastTranscriptShortcut.copy.refusal(isLocked: true) == "Unlock Hushy to copy your last dictation")
        #expect(LastTranscriptShortcut.paste.refusal(isLocked: false) == nil)
        #expect(LastTranscriptShortcut.copy.refusal(isLocked: false) == nil)
    }

    @Test("the shortcuts and the menu items follow one rule", arguments: [true, false])
    func oneRule(isLocked: Bool) {
        let allowed = LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: isLocked)
        for shortcut in [LastTranscriptShortcut.paste, .copy] {
            #expect((shortcut.refusal(isLocked: isLocked) == nil) == allowed)
        }
        #expect((NoFieldMode.offerCopy.recoveryLine(isLocked: isLocked) != nil) == allowed)
        #expect(NoFieldMode.offerCopy.namesCopyLast(isLocked: isLocked) == allowed)
    }

    @Test("the lines keep the app's voice: one line, telling the person to unlock Hushy")
    func voice() {
        for line in [LastTranscriptShortcut.paste.lockedNotice, LastTranscriptShortcut.copy.lockedNotice] {
            #expect(line.hasPrefix("Unlock Hushy"))
            for mark in ["!", "—", "–", "-", "\n", "⌃", "⌘"] { #expect(!line.contains(mark)) }
            let words = line.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(!words.contains("simply"))
            #expect(!words.contains("just"))
        }
    }

    // MARK: Through the controller

    @Test("locked, paste last pastes nothing and the pill says to unlock")
    func pasteLastLocked() throws {
        let harness = try Harness(isLocked: true)
        harness.controller.pasteLast()
        #expect(harness.pill.state == .error("Unlock Hushy to paste your last dictation"))
        #expect(!harness.controller.isBusy)
    }

    @Test("locked, copy last copies nothing: the pill says to unlock and never says Copied")
    func copyLastLocked() throws {
        let harness = try Harness(isLocked: true)
        harness.controller.copyLast()
        #expect(harness.pill.state == .error("Unlock Hushy to copy your last dictation"))
        #expect(harness.pill.state != .held(copied: true))
    }

    @Test("locked, a shortcut never takes away a card that still holds the words and its Copy")
    func recoveryRowStays() throws {
        let harness = try Harness(isLocked: true)
        harness.pill.present(.noField(.offerCopy), text: "The ferry leaves at nine.")
        harness.controller.copyLast()
        harness.controller.pasteLast()
        #expect(harness.pill.state == .noField(.offerCopy))
        #expect(harness.pill.state.recoveryActions.contains(.copy), "the card's own Copy is not behind the lock")
    }

    @Test("the notice is shown only on a free pill: not over a recording, not over a row that holds words")
    func noticeOnlyOnAFreePill() {
        #expect(LastTranscriptShortcut.showsNotice(isDictating: false, pillHoldsRecoveryRow: false))
        #expect(!LastTranscriptShortcut.showsNotice(isDictating: true, pillHoldsRecoveryRow: false))
        #expect(!LastTranscriptShortcut.showsNotice(isDictating: false, pillHoldsRecoveryRow: true))
    }

    // MARK: Recovery lines

    @Test("locked, no card names paste last; unlocked, every card does", arguments: RecoveryShortcutTests.cardModes)
    func cardLine(mode: NoFieldMode) {
        #expect(mode.recoveryLine(isLocked: true) == nil)
        #expect(mode.recoveryLine(isLocked: false) == ShortcutHelp.pasteLastLine)
    }

    @Test("locked, the capsule keeps its reason and drops the copy last keys", arguments: RecoveryShortcutTests.cardModes)
    func capsule(mode: NoFieldMode) {
        #expect(!mode.namesCopyLast(isLocked: true))
        #expect(mode.namesCopyLast(isLocked: false) == (mode.capsuleLabel != nil))
    }

    @Test("locked, VoiceOver is not told about paste last as a card appears")
    func announcement() {
        let pill = PillModel()
        pill.present(.noField(.offerCopy), text: "The ferry leaves at nine.")
        #expect(pill.recoveryAnnouncement?.contains("Command V") == true)
        pill.isAppLocked = { true }
        #expect(pill.recoveryAnnouncement == NoFieldMode.offerCopy.accessibilityText)
        #expect(pill.recoveryAnnouncement?.contains("ferry") == false)
    }
}
