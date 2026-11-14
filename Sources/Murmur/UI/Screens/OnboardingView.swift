import MurmurCore
import SwiftUI

/// Onboarding, paced to the speech-model download. The required flow is gate 11's five steps —
/// Welcome · Microphone · Accessibility · Try it now · You're set — and on a fast connection it
/// is exactly that: setup ends when the first dictation works. (The voice-action rehearsal that
/// used to follow Try it is now optional practice in Settings → Voice actions,
/// `VoiceActionRehearsalView`.) The model starts downloading at launch (`DownloadCoordinator`);
/// each time the user moves forward, `OnboardingFlow` re-runs `OnboardingPacing` with the live ETA:
///
/// - **fast**: nothing changes; the model is ready before "Try it".
/// - **slow**: a few optional, genuinely useful steps (practise the key, check the mic, add
///   names, pick a writing style, privacy in one screen) appear before "Try it", only while the
///   model is still coming, each skippable. They drop out the moment it's ready.
/// - **very slow / offline / metered**: "Try it" becomes an honest status ("still downloading,
///   4 min left — we'll let you know") and the user finishes anyway; one notification follows.
///
/// The first successful dictation on "Try it" completes onboarding (see
/// `AppModel.recordFirstDictation`); the closing step only holds optional choices.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Snapshot-only: the flow (sequence + current step) to open on.
    var initialFlow: OnboardingFlow?
    /// Snapshot-only proof of the successful Try it path.
    var snapshotFirstDictationWorked = false
    var snapshotPracticeOpen = false
    var snapshotTryItDone = false
    var snapshotMigratedFromMurmur: Bool?
    var snapshotKeyLesson: KeyGesturePractice?
    var snapshotKeyLessonBlocked = false
    @State private var flow = OnboardingFlow()
    @State private var tryText = ""
    @State private var tryStartedAt = Date()
    @State private var launchAtLogin = true
    @State private var showUsageNumbers = false
    @State private var movingForward = true
    /// Set when the Microphone or Accessibility pane was opened from this flow. "Waiting for
    /// permission…" stays hidden until then (`OnboardingDoneCopy.showsWaiting`).
    @State private var microphonePaneOpened = false
    @State private var accessibilityPaneOpened = false
    @State private var firstDictationWorked = false
    @State private var showActionPractice = false
    @State private var skippedActionPractice = false
    @FocusState private var practiceFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            OnboardingStepper(flow: flow, downloads: model.downloads, modelSizeText: modelSizeText)
                .frame(width: 260, alignment: .leading)
                .padding(Theme.Space.xxl)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.bgSunken.opacity(0.5))

            VStack(spacing: 0) {
                Spacer(minLength: Theme.Space.xl)
                Group { page(for: flow.current) }
                    .frame(maxWidth: 560)
                    .transition(.asymmetric(
                        insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)))
                    .id(flow.current)
                Spacer(minLength: Theme.Space.xl)
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bgBase)
        // Snapshot mode jumps straight to `initialFlow` in `onAppear`; animating that jump
        // would capture a half-faded stepper and a step sliding in mid-transition.
        .animation(isSnapshot ? nil : Theme.spatial(reduceMotion: reduceMotion), value: flow.current)
        .onAppear {
            if let initialFlow { flow = initialFlow }
            if isSnapshot {
                firstDictationWorked = snapshotFirstDictationWorked
                showActionPractice = snapshotPracticeOpen
            }
            guard !isSnapshot else { return }
            model.markOnboardingStarted()
            model.permissions.startPolling()
        }
        .onChange(of: model.permissions.microphone) { _, status in
            if flow.current == .microphone, status == .granted { advance(to: .accessibility) }
        }
        .onChange(of: model.permissions.accessibility) { _, status in
            if flow.current == .accessibility, status == .granted {
                model.installHotkeys()
                // System Settings is in front after the grant; Try it needs this window key.
                if !isSnapshot { model.openMainWindow() }
                advance()
            }
        }
    }

    // MARK: Navigation

    private var bottomBar: some View {
        HStack {
            if !flow.isFirst {
                Button("Back") { goBack() }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            // One way forward on Welcome (Get started) and on the close (its own button). Try it
            // has its own "Skip for now".
            if flow.current != .welcome, flow.current != .tryIt, flow.current != .invite, !flow.isLast {
                Button(flow.current.isOptional ? "Skip this step" : "Skip") { advance(skipped: true) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).font(Theme.Font.body)
            }
        }
        .padding(Theme.Space.xxl)
    }

    /// Optional steps whose preconditions hold right now.
    private var eligibleOptional: Set<OnboardingStep> {
        var eligible: Set<OnboardingStep> = [.dictionary, .writingStyle, .privacy]
        if model.permissions.microphone == .granted { eligible.insert(.micCheck) }
        return eligible
    }

    private func advance(skipped: Bool = false) {
        let leaving = flow.current
        if leaving == .tryIt, !skipped {
            firstDictationWorked = model.library.dictations.contains { OnboardingCopy.practiceCompleted($0, since: tryStartedAt) }
        }
        let next = flow.advancing(eta: model.downloads.eta, eligible: eligibleOptional, skipped: skipped)
        move(to: next, leaving: leaving, skipped: skipped)
    }

    private func advance(to step: OnboardingStep) {
        let leaving = flow.current
        move(to: flow.advancing(to: step, eta: model.downloads.eta, eligible: eligibleOptional), leaving: leaving, skipped: false)
    }

    private func move(to next: OnboardingFlow, leaving: OnboardingStep, skipped: Bool) {
        record(leaving: leaving, skipped: skipped, next: next)
        movingForward = true
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) { flow = next }
    }

    private func goBack() {
        movingForward = false
        withAnimation(Theme.spatial(reduceMotion: reduceMotion)) { flow = flow.goingBack() }
    }

    /// Funnel: which optional steps were shown or skipped, and the pace decided on leaving the
    /// permissions. Local only (`OnboardingFunnel`).
    private func record(leaving: OnboardingStep, skipped: Bool, next: OnboardingFlow) {
        if next.current == .tryIt { tryStartedAt = Date() }
        guard !isSnapshot else { return }
        if leaving.isOptional, skipped { model.funnel.recordOptionalStep(leaving, skipped: true) }
        if next.current.isOptional { model.funnel.recordOptionalStep(next.current, skipped: false) }
        if leaving == .accessibility, let pace = next.lastPace { model.funnel.recordPace(pace) }
    }

    /// The speech model for the current language setting, then the writing model(s) this Mac gets
    /// (`ModelTierPolicy.firstRunWritingDownloads`), when the writing model is the local one.
    private var modelSizeText: String {
        let speech = SpeechEngine.expectedDownloadBytes(for: model.settings.speechLanguageMode.modelVersion)
        let writing = model.settings.cleanupBackend == .local
            ? ModelTierPolicy.firstRunWritingDownloads(for: .current(), prefer2B: model.settings.preferIntentCleanup2B)
                .reduce(Int64(0)) { $0 + $1.downloadBytes }
            : 0
        return OnboardingCopy.modelSizeLine(speechBytes: speech, writingBytes: writing)
    }

    // MARK: Pages

    @ViewBuilder private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: welcome
        case .microphone: microphone
        case .accessibility: accessibility
        case .hotkeyPractice: OnboardingKeyStep(onContinue: { advance() }, snapshot: snapshotKeyLesson,
                                                snapshotAccessibilityOff: snapshotKeyLessonBlocked)
        case .tryIt: tryIt
        case .done: done
        // The invite step is never offered (Pro removed, founder 2026-11-11); it shares the plain
        // Continue page so a flow can never stop on it.
        case .micCheck, .dictionary, .writingStyle, .privacy, .invite:
            WaitingStepView(step: step) { advance() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Talk.\nIt types.\nYour voice never leaves this Mac.")
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
            // The usage-numbers switch is on screen, off, before anything is recorded: pressing "Get
            // started" is what marks it as seen (`AppSettings.usageNumbersNoticeSeen`).
            UsageNumbersOnboardingRow(
                isOn: Binding(get: { model.settings.shareUsageNumbers }, set: { model.settings.shareUsageNumbers = $0 }),
                showDisclosure: $showUsageNumbers)
            Button("Get started") {
                if !isSnapshot { model.settings.usageNumbersNoticeSeen = true }
                advance()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, Theme.Space.s)
        }
        .sheet(isPresented: $showUsageNumbers) { UsageNumbersSheet() }
    }

    private var microphone: some View {
        StepLayout(
            symbol: "mic.fill",
            title: "Let Hushy hear you",
            message: OnboardingCopy.microphoneMessage
        ) {
            if model.permissions.microphone == .granted {
                GrantedLabel(text: "Microphone allowed")
                MicCheck(isSnapshot: isSnapshot)
                Button("Continue") { advance() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                let denied = model.permissions.microphone == .denied
                Button(denied ? OnboardingDoneCopy.openMicrophoneSettings : "Allow microphone") {
                    if denied { microphonePaneOpened = true }
                    Task { await model.permissions.requestMicrophone() }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                if OnboardingDoneCopy.showsWaiting(
                    for: .openMicrophoneSettings, microphonePaneOpened: microphonePaneOpened, accessibilityPaneOpened: false) {
                    Text(OnboardingDoneCopy.waitingForPermission)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var accessibility: some View {
        StepLayout(
            symbol: "keyboard",
            title: "Let Hushy type for you",
            message: OnboardingCopy.accessibilityMessage(
                triggerGlyph: model.settings.triggerKey.glyph, isGranted: model.permissions.accessibility == .granted)
        ) {
            if model.permissions.accessibility == .granted {
                GrantedLabel(text: "Accessibility allowed")
                Button("Continue") { advance() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(OnboardingDoneCopy.openAccessibilitySettings) {
                    accessibilityPaneOpened = true
                    model.permissions.requestAccessibility()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                if OnboardingDoneCopy.showsWaiting(
                    for: .openAccessibilitySettings, microphonePaneOpened: false,
                    accessibilityPaneOpened: accessibilityPaneOpened) {
                    Text(OnboardingDoneCopy.waitingForPermission)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var tryIt: some View {
        let latest = model.library.dictations.first { OnboardingCopy.practiceCompleted($0, since: tryStartedAt) }
            ?? (isSnapshot && snapshotTryItDone ? Dictation(
                rawText: "Let's meet at ten, no, nine, and bring your laptop.",
                text: "Let's meet at nine and bring your laptop.", durationSeconds: 4.2,
                latencyMs: 340, status: .inserted) : nil)
        let variant = OnboardingPacing.tryItVariant(for: model.downloads.eta)
        switch (latest, variant) {
        case (nil, .stillDownloading), (nil, .waiting):
            TryItWaiting(
                variant: variant, downloads: model.downloads, triggerGlyph: model.settings.triggerKey.glyph,
                onFinish: {
                    model.downloads.notifyWhenReady()
                    advance()
                })
        default:
            practice(latest: latest)
        }
    }

    private func practice(latest: Dictation?) -> some View {
        let glyph = model.settings.triggerKey.glyph
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Try it now").font(Theme.Font.section)
            Text(OnboardingCopy.tryItLead(triggerGlyph: glyph))
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            OnboardingPracticeChat(
                text: $tryText, focused: $practiceFocused, latest: latest, triggerGlyph: glyph, isSnapshot: isSnapshot)
            if latest != nil {
                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                // Ready needs no words: the field's accent ring says it. Only a wait is spelled out.
                if !model.downloads.status.isReady { ModelReadiness(downloads: model.downloads) }
                Button("Skip for now") {
                    if !model.modelStatus.isReady { model.downloads.notifyWhenReady() }
                    advance(skipped: true)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).font(Theme.Font.body)
            }
        }
        .animation(isSnapshot ? nil : Theme.spatial(reduceMotion: reduceMotion), value: latest?.id)
        // The reply is sent: its words leave the field for the bubble above it.
        .onChange(of: latest?.id) { _, id in if id != nil { tryText = "" } }
        .onAppear {
            // The field is ready for the first double-tap: a double-tap before the person clicks in would
            // otherwise dictate into whichever app is in front. Next turn, once the editor exists.
            guard !isSnapshot else { return }
            DispatchQueue.main.async { practiceFocused = true }
        }
    }

    /// The closing step. "You're set." only once dictation can work. A skipped or missing
    /// Microphone or Accessibility grant says "Almost." and the one button opens that pane.
    /// While the speech model is still on its way, and access is already granted, the step says
    /// so instead (`OnboardingDoneCopy`).
    private var done: some View {
        let almost = OnboardingDoneCopy.almost(
            microphone: model.permissions.microphone, accessibility: model.permissions.accessibility,
            skipped: flow.skippedPermissions)
        let pending = almost == nil ? OnboardingDoneCopy.wait(
            isReady: model.modelStatus.isReady, isLoading: model.modelStatus.state == .loading,
            eta: model.downloads.eta, download: model.modelStatus.download
        ).map { OnboardingDoneCopy.pending($0, triggerGlyph: model.settings.triggerKey.glyph) } : nil
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(almost == nil ? (pending?.title ?? "You're set.") : OnboardingDoneCopy.almostTitle)
                .font(Theme.Font.hero)
            Text(almost?.message ?? pending?.message ?? OnboardingDoneCopy.readyMessage(triggerGlyph: model.settings.triggerKey.glyph))
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let pending {
                if let progress = pending.progressLine {
                    Label(progress, systemImage: "arrow.down.circle")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Label(pending.readyLine, systemImage: "bell")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let almost, OnboardingDoneCopy.showsWaiting(
                for: almost.fix, microphonePaneOpened: microphonePaneOpened,
                accessibilityPaneOpened: accessibilityPaneOpened) {
                Text(OnboardingDoneCopy.waitingForPermission)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if OnboardingDoneCopy.showsMurmurMigration(movedSupportDirectory: snapshotMigratedFromMurmur ?? model.migratedFromMurmur) {
                Label("Moving from Murmur? Your data comes with you.", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Font.caption).foregroundStyle(Theme.phosphor)
            }
            if OnboardingVoiceActionOffer.isShown(
                firstDictationWorked: firstDictationWorked, hasPermissionGap: almost != nil,
                isModelPending: pending != nil, skipped: skippedActionPractice) {
                actionPractice
            }
            Toggle("Open Hushy at login", isOn: $launchAtLogin).toggleStyle(.checkbox)
            if let almost {
                Button(almost.buttonTitle) { openPermission(almost.fix) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(pending?.buttonTitle ?? "Start using Hushy") {
                    // `completeOnboarding` asks for the one "ready" notification when the model is not
                    // ready yet, which is the promise the pending screen makes.
                    model.settings.launchAtLogin = launchAtLogin
                    model.completeOnboarding()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var actionPractice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if showActionPractice {
                VoiceActionRehearsalView(mode: .onboarding, onDone: { showActionPractice = false })
            } else {
                Text("Want to try a voice action?").font(Theme.Font.emphasis)
                Text(OnboardingVoiceActionOffer.instruction(
                    dictation: model.settings.triggerKey, action: model.settings.actionTrigger))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Text("Try “\(VoiceActionRehearsal.prompt).”")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Text(OnboardingVoiceActionOffer.practiceNotice)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.Space.m) {
                    Button("Try it") { showActionPractice = true }.buttonStyle(SecondaryButtonStyle())
                    Button("Skip voice action") { skippedActionPractice = true }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// The closing step's one button, when access is still missing: the system prompt, or the
    /// System Settings pane. Waiting copy appears only after a pane opens.
    private func openPermission(_ fix: OnboardingDoneCopy.Fix) {
        switch fix {
        case .allowMicrophone:
            Task { await model.permissions.requestMicrophone() }
        case .openMicrophoneSettings:
            microphonePaneOpened = true
            model.permissions.startPolling()
            Task { await model.permissions.requestMicrophone() }
        case .openAccessibilitySettings:
            accessibilityPaneOpened = true
            model.permissions.requestAccessibility()
        }
    }
}
