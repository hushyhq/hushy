import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Sentences an independent review found untrue, written for engineers, or leaving a new person
/// stuck (interface batch one, 2026-10-11). Each test holds a sentence to what the app does, so
/// the words cannot drift back.
@MainActor
@Suite("Interface copy")
struct InterfaceCopyTests {
    // MARK: Onboarding

    @Test("the microphone step is true for holding the key and for hands-free")
    func microphoneStep() {
        let message = OnboardingCopy.microphoneMessage
        #expect(!message.contains("only on while you hold"), "one tap also starts hands-free dictation")
        // One line since 2026-10-28: "when you dictate" covers holding the key and one tap for hands-free.
        #expect(message.contains("only when you dictate"))
        #expect(message.contains("stays on this Mac"))
        #expect(message.split(separator: " ").count <= 14)
    }

    @Test("the accessibility step offers one way forward in each state")
    func accessibilityStep() {
        let waiting = OnboardingCopy.accessibilityMessage(triggerGlyph: "fn", isGranted: false)
        let granted = OnboardingCopy.accessibilityMessage(triggerGlyph: "fn", isGranted: true)
        #expect(waiting.contains("moves on by itself"))
        #expect(!granted.contains("by itself"), "granted shows a Continue button; it must not also promise to move on")
        #expect(granted.contains("double-tap fn"), "the main gesture is taught first")
        #expect(!granted.contains("hold fn"))
    }

    @Test("Try it does not assume a mouse, and asks for a short sentence first")
    func tryItWording() {
        #expect(OnboardingCopy.tryItLead(triggerGlyph: "fn") == "Double-tap fn, say something, press Enter.")
        #expect(OnboardingCopy.tryItAlternative(triggerGlyph: "fn") == "Or hold fn while you talk.")
        #expect(!OnboardingCopy.tryItLead(triggerGlyph: "fn").localizedCaseInsensitiveContains("click"))
        // The suggestion is its own string, the same messy sentence Home offers.
        #expect(OnboardingCopy.tryItSuggestion == "Try: \u{201C}Let's meet at ten, no, nine, and bring your laptop.\u{201D}")
        #expect(OnboardingCopy.tryItSuggestion.contains(HomeFeedCopy.tryItSentence))
        #expect(!OnboardingCopy.practicePlaceholder(triggerGlyph: "fn").localizedCaseInsensitiveContains("click"))
    }

    @Test("the download line names the speech model and the writing model this Mac gets")
    func modelSizeLine() {
        #expect(OnboardingCopy.modelSizeLine(speechBytes: 632_000_000, writingBytes: nil) == "About 632 MB, once")
        #expect(OnboardingCopy.modelSizeLine(speechBytes: 632_000_000, writingBytes: 0) == "About 632 MB, once")
        #expect(OnboardingCopy.modelSizeLine(speechBytes: 632_000_000, writingBytes: 1_080_000_000)
            == "632 MB speech, then about 1.08 GB writing model, once")
    }

    @Test("the Account section no longer claims Free never needs an account")
    func accountCopy() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/MurmurTests/InterfaceCopyTests.swift",
            with: "Sources/Murmur/UI/Screens/Settings/AccountSettingsSection.swift"), encoding: .utf8)
        #expect(!source.contains("never needs an account"))
    }

    @Test("the closing step says Almost when Microphone or Accessibility is still missing")
    func doneStepAlmost() {
        let skippedMic = OnboardingDoneCopy.almost(microphone: .notDetermined, accessibility: .granted, skipped: [.microphone])
        #expect(skippedMic?.buttonTitle == "Allow microphone")
        #expect(skippedMic?.fix == .allowMicrophone)
        #expect(OnboardingDoneCopy.showsWaiting(for: .allowMicrophone, microphonePaneOpened: true, accessibilityPaneOpened: true) == false)

        let denied = OnboardingDoneCopy.almost(microphone: .denied, accessibility: .denied, skipped: [.microphone])
        #expect(denied?.buttonTitle == OnboardingDoneCopy.openMicrophoneSettings)
        #expect(denied?.fix == .openMicrophoneSettings)
        #expect(denied?.message.contains("cannot hear you yet") == true)
        #expect(OnboardingDoneCopy.showsWaiting(for: .openMicrophoneSettings, microphonePaneOpened: false, accessibilityPaneOpened: false) == false)
        #expect(OnboardingDoneCopy.showsWaiting(for: .openMicrophoneSettings, microphonePaneOpened: true, accessibilityPaneOpened: false))

        let access = OnboardingDoneCopy.almost(microphone: .granted, accessibility: .denied, skipped: [.accessibility])
        #expect(access?.buttonTitle == OnboardingDoneCopy.openAccessibilitySettings)
        #expect(access?.fix == .openAccessibilitySettings)
        #expect(OnboardingDoneCopy.showsWaiting(for: .openAccessibilitySettings, microphonePaneOpened: false, accessibilityPaneOpened: false) == false)
        #expect(OnboardingDoneCopy.showsWaiting(for: .openAccessibilitySettings, microphonePaneOpened: false, accessibilityPaneOpened: true))

        #expect(OnboardingDoneCopy.almost(microphone: .granted, accessibility: .granted, skipped: [.microphone, .accessibility]) == nil,
                "a grant after Skip is You're set")
        #expect(OnboardingDoneCopy.almostTitle == "Almost.")
        #expect(OnboardingDoneCopy.waitingForPermission == "Waiting for permission…")
    }

    @Test("the closing step is You're set only when dictation can work")
    func doneStepWaits() {
        let half = ModelDownloadProgress(fraction: 0.5, expectedBytes: 632_000_000, estimatedSecondsRemaining: 230)
        #expect(OnboardingDoneCopy.wait(isReady: true, isLoading: false, eta: .ready, download: nil) == nil)
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: true, eta: .seconds(5), download: nil) == .preparing)
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: false, eta: .seconds(230), download: half)
            == .downloading(progress: "316 of ~632 MB · about 4 min left"))
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: false, eta: .estimating, download: nil) == .downloading(progress: nil))
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: false, eta: .waiting(.offline), download: half) == .offline)
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: false, eta: .waiting(.meteredNetwork), download: nil) == .meteredNetwork)
        #expect(OnboardingDoneCopy.wait(isReady: false, isLoading: false, eta: .waiting(.failed), download: half) == .failed)
    }

    @Test("while the speech model is on its way the closing step says so, and how you will know")
    func doneStepPendingCopy() {
        let downloading = OnboardingDoneCopy.pending(.downloading(progress: "316 of ~632 MB · about 4 min left"), triggerGlyph: "fn")
        #expect(downloading.title == "Setup is done.")
        #expect(downloading.message.hasPrefix("Dictation is still downloading and will not work until that finishes."))
        #expect(downloading.progressLine == "Speech model · 316 of ~632 MB · about 4 min left")
        #expect(downloading.buttonTitle == "Open Hushy while it downloads")
        // What the app really does when the model lands: one notification, and Home's readiness card.
        #expect(downloading.readyLine.contains("one notification when dictation is ready, if you allow notifications"))
        #expect(downloading.readyLine.contains("Home shows the speech model until then"))
        #expect(downloading.readyLine.contains("double-tap fn in any app, talk, and press Enter"))
        #expect(!downloading.readyLine.contains("hold fn"))
        #expect(OnboardingCopy.tryItWaitingLead.contains("double-tap"))
        #expect(OnboardingCopy.tryItWaitingTail == "to talk, then press Enter.")

        let waits: [OnboardingDoneCopy.Wait] = [.downloading(progress: nil), .preparing, .offline, .meteredNetwork, .failed]
        for wait in waits {
            let pending = OnboardingDoneCopy.pending(wait, triggerGlyph: "fn")
            #expect(!pending.title.contains("You're set"), "\(wait)")
            #expect(pending.buttonTitle.hasPrefix("Open Hushy"), "\(wait)")
            #expect(!pending.buttonTitle.contains("Start using"), "\(wait)")
        }
        #expect(OnboardingDoneCopy.pending(.offline, triggerGlyph: "fn").buttonTitle == "Open Hushy", "nothing is downloading while offline")
        #expect(OnboardingDoneCopy.pending(.offline, triggerGlyph: "fn").message.contains("back online"))
        #expect(OnboardingDoneCopy.pending(.meteredNetwork, triggerGlyph: "fn").message.contains("Wi-Fi"))
        #expect(OnboardingDoneCopy.pending(.failed, triggerGlyph: "fn").message.contains("retry from Home"))
        #expect(OnboardingDoneCopy.pending(.preparing, triggerGlyph: "fn").progressLine == nil)
    }

    @Test("the menu bar names Dictate and Hushy, and Start waits until dictation can work")
    func menuBarCopy() {
        #expect(MenuBarCopy.dictateMenu == "Dictate")
        #expect(MenuBarCopy.startHandsFree == "Start hands-free")
        #expect(MenuBarCopy.stopHandsFree == "Stop hands-free")
        #expect(MenuBarCopy.dictateKey == "Dictate key")
        let ready = DictationReadinessStatus.compute(
            modelState: .ready, microphone: .granted, accessibility: .granted, triggerKey: .fn,
            fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false)
        #expect(ready.kind == .ready)
        #expect(MenuBarCopy.statusLine(recordingNote: false, readiness: ready) == ready.text)
        #expect(MenuBarCopy.statusLine(recordingNote: true, readiness: ready) == "Recording a note…")
        #expect(MenuBarCopy.handsFreeEnabled(isBusy: false, readiness: ready))
        #expect(MenuBarCopy.handsFreeEnabled(isBusy: true, readiness: ready))
        let blocked = DictationReadinessStatus.compute(
            modelState: .ready, microphone: .denied, accessibility: .granted, triggerKey: .fn,
            fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false)
        #expect(MenuBarCopy.statusLine(recordingNote: false, readiness: blocked) == blocked.text)
        #expect(!MenuBarCopy.handsFreeEnabled(isBusy: false, readiness: blocked))
        #expect(MenuBarCopy.handsFreeEnabled(isBusy: true, readiness: blocked), "Stop stays available")
    }

    @Test("You're set leads with dictation in the person's own key, with no plan talk")
    func doneStepReady() {
        let message = OnboardingDoneCopy.readyMessage(triggerGlyph: "right ⌥")
        #expect(message == "Double-tap right ⌥ to talk, Enter to paste. Hold fn + control for an action.")
        for banned in ["Free", "Pro", "a month", "—"] {
            #expect(!message.contains(banned), "\(banned)")
        }
    }

    @Test("Murmur line appears only after support data was moved")
    func migrationLine() {
        #expect(OnboardingDoneCopy.showsMurmurMigration(movedSupportDirectory: true))
        #expect(!OnboardingDoneCopy.showsMurmurMigration(movedSupportDirectory: false))
    }

    // MARK: Pill and gate

    @Test("a microphone that will not start says where to look, on one short line")
    func microphoneFailure() {
        let message = PillModel.microphoneFailedMessage
        #expect(message.contains("Settings → General"), "the Microphone row lives there")
        #expect(!message.contains("\n"))
        #expect(message.count <= 44, "the error row is one line and never wraps")
        #expect(DictationFailure.persistent(message: message) == .didNotStart(message))
        #expect(PillState.failed(.didNotStart(message)).isInteractive, "the row stays, with ✕")
        #expect(PillState.failed(.didNotStart(message)).selfDismissDelay == nil)
        #expect(DictationFailure.persistent(message: DictationFailure.noteIncompleteMessage) == .noteIncomplete)
        #expect(DictationFailure.noteIncomplete.line == "Note incomplete")
        #expect(PillState.failed(.noteIncomplete).selfDismissDelay == nil)
    }

    @Test("the waiting screen says access is pending and how to check, names nobody and promises no email")
    func betaGateWaiting() {
        let message = BetaGateView.waitingMessage
        #expect(message.contains("pending"))
        #expect(message.contains("Check again"))
        #expect(!message.localizedCaseInsensitiveContains("founder"))
        #expect(!message.localizedCaseInsensitiveContains("email"))
    }

    // MARK: Settings

    @Test("the language rows say what happens without naming models or fallbacks")
    func languageRows() {
        let rows = [AppSettings.SpeechLanguageMode.settingsDetail] + AppSettings.SpeechLanguageMode.allCases.map(\.downloadDetail)
        for row in rows {
            #expect(!row.localizedCaseInsensitiveContains("fallback"), "\(row)")
            #expect(!row.localizedCaseInsensitiveContains("re-checked"), "\(row)")
        }
        #expect(AppSettings.SpeechLanguageMode.settingsDetail.contains("corrects itself if it mishears another language"))
        #expect(AppSettings.SpeechLanguageMode.englishOnly.downloadDetail.contains("450 MB"), "the second download is a fact the person needs")
    }

    @Test("the Privacy footnote is true with the Assistant or a connected AI app on")
    func networkRow() {
        let detail = PrivacySettingsPane.networkDetail
        #expect(!detail.contains("never touch the network"))
        #expect(!detail.localizedCaseInsensitiveContains("notes never"), "the Assistant sends notes when asked")
        #expect(detail.contains("on this Mac"))
        #expect(detail.contains("by itself"))
        #expect(detail.contains("Connected AI apps"))
        #expect(!detail.contains("AI connections"), "that pane no longer exists")
    }

    @Test("the Assistant's title and explanation agree: notes and meetings, never dictations")
    func assistantRow() {
        #expect(!AssistantConsent.title.localizedCaseInsensitiveContains("history"), "History is the dictation list, which it never reads")
        #expect(AssistantConsent.title.contains("notes"))
        #expect(AssistantSettingsSection.chatDetail.contains("notes and meetings"))
        #expect(AssistantSettingsSection.chatDetail.contains("Claude Code"))
        #expect(AssistantSettingsSection.chatDetail.contains("coming soon"))
        #expect(AssistantSettingsSection.chatDetail.contains("never shared"))
        #expect(!AssistantAgentCopy.offCardTitle.localizedCaseInsensitiveContains("or codex"))
        // The code the words describe: the Assistant's scope has no dictation tools.
        #expect(!MCPServer.notesToolNames.contains("search_history"))
        #expect(!MCPServer.notesToolNames.contains("recent_dictations"))
    }

    @Test("connected apps are told apart from the Assistant, and their reach is stated")
    func connectorRows() {
        #expect(!MCPServer.toolNames.contains("search_history"))
        #expect(AIConnectionsCopy.connectorScopeDetail.contains("dictation history"))
        #expect(AIConnectionsCopy.connectorScopeDetail.contains("notes and meetings"))
        #expect(AIConnectionsCopy.connectorScopeDetail.contains("cannot change anything"))
        #expect(!AIConnectionsCopy.connectorScopeDetail.contains("above"), "the Assistant is no longer on screen above it")

        let connector = AIConnectionsCopy.connectorDetail(clientTitle: "Claude Code", isAlsoAssistantAgent: true, status: .notConnected)
        let account = AIConnectionsCopy.assistantAccountDetail(agentTitle: "Claude Code", state: .ready)
        #expect(connector.hasPrefix("Separate from the Assistant"))
        #expect(connector.hasSuffix("Not connected."))
        #expect(account.hasPrefix("The Assistant asks through this account."))
        #expect(account.hasSuffix("Signed in."))
        for state in [AgentAccountState.notInstalled, .signedOut, .ready, .unknown] {
            #expect(AIConnectionsCopy.assistantAccountDetail(agentTitle: "Claude Code", state: state).contains("Assistant"))
        }
        for status in [MCPInstaller.ConnectionStatus.notInstalled, .notConnected, .connected] {
            let cursor = AIConnectionsCopy.connectorDetail(clientTitle: "Cursor", isAlsoAssistantAgent: false, status: status)
            #expect(cursor.hasPrefix("Lets Cursor read Hushy"))
        }
    }

    // MARK: Empty states

    @Test("Home's empty Today says what appears and how to start with the person's own key")
    func homeTodayEmpty() {
        #expect(!HomeFeedCopy.todayEmptyTitle.contains("land here"))
        #expect(HomeFeedCopy.todayEmptyTitle.contains("dictations appear here"))
        let message = HomeFeedCopy.todayEmptyMessage(triggerGlyph: "right ⌥")
        #expect(message.contains("Double-tap right ⌥"))
        #expect(message.contains("Double-tap right ⌥ to talk, Enter to paste."))
    }

    @Test("before the first dictation the card invites a try only when dictation can work")
    func homeLastEmpty() {
        #expect(HomeFeedCopy.tryItTitle == "Try it now")
        let ready = HomeFeedCopy.tryItMessage(triggerGlyph: "right ⌥")
        #expect(ready == "Double-tap right ⌥, say it, then press Enter to paste. Your words show up here.")
        #expect(HomeFeedCopy.tryItSentence.contains("ten, no, nine"), "a self-correction, so cleanup has something to show")
        #expect(!HomeFeedCopy.lastEmptyWaiting.localizedCaseInsensitiveContains("try"), "a dictation cannot work yet")
        #expect(HomeFeedCopy.lastEmptyWaiting.contains("When dictation is ready"))
    }

    @Test("History's empty state says what is kept and how to start, in its own words")
    func historyEmpty() {
        #expect(!HistoryCopy.emptyTitle.contains("land here"))
        #expect(HistoryCopy.emptyTitle == "Your dictations are listed here")
        let message = HistoryCopy.emptyMessage(triggerGlyph: "right ⌥")
        #expect(message.contains("Hold right ⌥ in any app and talk"))
        #expect(message.contains("on this Mac"))
        #expect(HistoryCopy.emptyTitle != HomeFeedCopy.todayEmptyTitle)
        #expect(message != HomeFeedCopy.todayEmptyMessage(triggerGlyph: "right ⌥"))
    }

    @Test("the Voices empty state is short and points at its own button")
    func voicesEmpty() {
        #expect(!VoicesListView.emptyMessage.contains("→"), "the old Settings → General → … path was cut off mid-arrow")
        #expect(VoicesListView.emptyMessage.contains("button below"))
        #expect(VoicesListView.emptyMessage.contains("Nothing is remembered until you choose it."))
    }

    // MARK: Voice

    @Test("the new sentences keep the app's voice: no exclamation marks, em dashes, simply or just")
    func voice() {
        var sentences: [String] = [
            OnboardingCopy.microphoneMessage,
            OnboardingCopy.accessibilityMessage(triggerGlyph: "fn", isGranted: false),
            OnboardingCopy.tryItLead(triggerGlyph: "fn"), OnboardingCopy.tryItAlternative(triggerGlyph: "fn"),
            OnboardingCopy.practicePlaceholder(triggerGlyph: "fn"),
            OnboardingDoneCopy.almostTitle, OnboardingDoneCopy.waitingForPermission,
            OnboardingDoneCopy.openMicrophoneSettings, OnboardingDoneCopy.openAccessibilitySettings,
            PillModel.microphoneFailedMessage, PillModel.returnNotPressed,
            PillModel.doneExplanation(asHeard: true, notSent: true),
            BetaGateView.waitingMessage, PrivacySettingsPane.networkDetail,
            AssistantConsent.title, AssistantSettingsSection.chatDetail,
            AssistantAgentCopy.offCardTitle, AssistantAgentCopy.offCardDetail, AssistantAgentCopy.offCardInstallLine,
            AIConnectionsCopy.connectorsTitle, AIConnectionsCopy.connectorScopeDetail,
            HomeFeedCopy.todayEmptyTitle, HomeFeedCopy.todayEmptyMessage(triggerGlyph: "fn"),
            VoicesListView.emptyMessage, VoiceActionRehearsal.settingsRowDetail, VoiceActionRehearsal.notReadyLine,
            OnboardingDoneCopy.readyMessage(triggerGlyph: "fn"), HistoryCopy.emptyTitle, HistoryCopy.emptyMessage(triggerGlyph: "fn"),
            AppSettings.SpeechLanguageMode.settingsDetail,
            HomeFeedCopy.lastDictationTitle, HomeFeedCopy.tryItTitle,
            HomeFeedCopy.tryItMessage(triggerGlyph: "fn"), HomeFeedCopy.lastEmptyWaiting,
            HomeLastDictation.notTypedNote, HomeLastDictation.asHeardNote,
            HistorySelection.modeTitle, HistorySelection.title(count: 0), HistorySelection.title(count: 2),
            HistorySelection.hint(count: 0), HistorySelection.hint(count: 2),
            HistorySelection.paneMessage(count: 0), HistorySelection.paneMessage(count: 2),
        ]
        sentences += HistoryScope.allCases.map(\.title)
        sentences += [UpdateCopy.readyTitle, UpdateCopy.readyDetail, UpdateCopy.relaunchNow, UpdateCopy.later,
                      UpdateCopy.whatsNew, UpdateCopy.switchTitle, UpdateCopy.switchDetail,
                      UpdateCopy.statusText(installsAutomatically: true), UpdateCopy.statusText(installsAutomatically: false),
                      UpdateCopy.statusText(installsAutomatically: false, checksAutomatically: false)]
        sentences.append(AIConnectionsCopy.connectorDetail(clientTitle: "Claude Code", isAlsoAssistantAgent: true, status: .connected))
        sentences.append(AIConnectionsCopy.assistantAccountDetail(agentTitle: "Claude Code", state: .signedOut))
        sentences += AppSettings.SpeechLanguageMode.allCases.map(\.downloadDetail)
        sentences += [WritingPhase.stillWritingMessage, PillModel.quickCleanupLine, DictationFailure.noteIncompleteMessage,
                      MenuBarCopy.dictateMenu, MenuBarCopy.startHandsFree, MenuBarCopy.stopHandsFree, MenuBarCopy.dictateKey]
        if let denied = OnboardingDoneCopy.almost(microphone: .denied, accessibility: .granted, skipped: [.microphone]) {
            sentences += [denied.message, denied.buttonTitle]
        }
        if let waiting = OnboardingDoneCopy.almost(microphone: .notDetermined, accessibility: .granted, skipped: []) {
            sentences += [waiting.message, waiting.buttonTitle]
        }
        if let access = OnboardingDoneCopy.almost(microphone: .granted, accessibility: .denied, skipped: [.accessibility]) {
            sentences += [access.message, access.buttonTitle]
        }
        let waits: [OnboardingDoneCopy.Wait] = [.downloading(progress: nil), .preparing, .offline, .meteredNetwork, .failed]
        for wait in waits {
            let pending = OnboardingDoneCopy.pending(wait, triggerGlyph: "fn")
            sentences += [pending.title, pending.message, pending.readyLine, pending.buttonTitle]
        }
        for sentence in sentences {
            #expect(!sentence.contains("!"), "\(sentence)")
            #expect(!sentence.contains("—"), "\(sentence)")
            let words = sentence.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(!words.contains("simply"), "\(sentence)")
            #expect(!words.contains("just"), "\(sentence)")
        }
    }
}
