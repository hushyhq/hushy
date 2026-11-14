import MurmurCore
import SwiftUI

/// Home's lead: one raised card in two bands. The top band answers the two questions a person
/// opens the window with, "can I dictate right now" and "how do I start", around a large cap of
/// their own dictation key; when something blocks dictation it says what, and carries the one
/// button that fixes it (`DictationHeroCopy`, from the same readiness the sidebar row shows).
/// The lower band is the most recent dictation, readable, with Copy and Open in History
/// (`HomeLastDictation`); before the first dictation it says what will appear there.
///
/// Lime is the person's own energy, so it marks the live key and the single main button: the
/// fix while dictation is blocked, otherwise Copy.
struct HomeDictationHero: View {
    @Environment(AppModel.self) private var model
    /// The readiness `HomeView` computed for this pass (one computation serves the whole page).
    let status: DictationReadinessStatus
    /// What Home is showing: the library's dictations, or a snapshot fixture's.
    let dictations: [Dictation]
    let now: Date
    let calendar: Calendar
    /// The app lock is on: the card keeps its readiness half and shows no dictated words.
    let isLocked: Bool

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // While the speech model loads, the card follows the clock: how far a stage is through
        // its usual time changes by the half second. A still uses the page's own "now".
        if let progress = model.modelStatus.loadProgress, status.reason == .modelLoading {
            if isSnapshot {
                card(load: progress.display(at: now))
            } else {
                TimelineView(.periodic(from: .now, by: LoadStageTrack.tick)) { context in
                    card(load: progress.display(at: context.date))
                }
            }
        } else {
            card(load: nil)
        }
    }

    private func card(load: SpeechLoadProgress.Display?) -> some View {
        let glyph = model.settings.triggerKey.glyph
        let copy = DictationHeroCopy.make(
            status: status, triggerGlyph: glyph, modelState: model.modelStatus.state,
            download: model.modelStatus.download, load: load,
            afterOnboarding: model.settings.hasCompletedOnboarding)
        let alsoNeedsAccessibility = model.settings.hasCompletedOnboarding
            && model.permissions.microphone != .granted && model.permissions.accessibility != .granted
        return DictationHeroCard(
            copy: copy, kind: status.kind, triggerGlyph: glyph,
            content: HomeCardContent.make(
                isLocked: isLocked, dictations: dictations, isReady: copy.isReady, now: now, calendar: calendar),
            onFix: { model.runReadinessFix(status.fix) },
            additionalFixTitle: alsoNeedsAccessibility ? "Allow Accessibility" : nil,
            additionalDetail: alsoNeedsAccessibility
                ? "Accessibility also needs to be allowed so the \(glyph) key works. If Hushy is already on in the list, remove it with −, then add it again."
                : nil,
            onAdditionalFix: { model.runReadinessFix(.requestAccessibility) },
            onCopy: { TextInserter.copy($0) },
            onOpenInHistory: { model.openHistoryItem($0) },
            onUnlock: { Task { _ = await model.appLock.unlock() } })
            .onAppear { model.permissions.refresh() }
    }
}

/// The card itself, from plain values: it reads nothing and does nothing on its own.
struct DictationHeroCard: View {
    let copy: DictationHeroCopy
    let kind: DictationReadinessStatus.Kind
    let triggerGlyph: String
    let content: HomeCardContent
    let onFix: () -> Void
    var additionalFixTitle: String? = nil
    var additionalDetail: String? = nil
    var onAdditionalFix: () -> Void = {}
    let onCopy: (String) -> Void
    let onOpenInHistory: (Int64) -> Void
    let onUnlock: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DictationStatusBand(copy: copy, kind: kind, triggerGlyph: triggerGlyph, onFix: onFix,
                                additionalFixTitle: additionalFixTitle, additionalDetail: additionalDetail,
                                onAdditionalFix: onAdditionalFix)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            LastDictationBand(
                content: content, isReady: copy.isReady, triggerGlyph: triggerGlyph,
                onCopy: onCopy, onOpenInHistory: onOpenInHistory, onUnlock: onUnlock)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: scheme == .dark ? .clear : Theme.cardShadow.opacity(Theme.cardShadowOpacity + 0.04), radius: 18, y: 6)
    }
}

/// The card's top band: the key, the state word, the headline, then either how to start (ready)
/// or why not and the fix.
private struct DictationStatusBand: View {
    let copy: DictationHeroCopy
    let kind: DictationReadinessStatus.Kind
    let triggerGlyph: String
    let onFix: () -> Void
    let additionalFixTitle: String?
    let additionalDetail: String?
    let onAdditionalFix: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            DictationKeyCap(glyph: triggerGlyph, isLive: copy.isReady)
                .padding(.top, Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                stateLine
                Text(copy.headline)
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                // Loading and ready take the same room, so the card does not change size when the
                // model becomes ready: one fades out as the other fades in.
                Group {
                    if copy.isReady {
                        HowToStartLines(lines: DictationHeroCopy.howToStart(triggerGlyph: triggerGlyph))
                            .transition(Self.crossFade)
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Space.s) { blockedBody }
                            .transition(Self.crossFade)
                    }
                }
                .frame(minHeight: copy.isReady || copy.load != nil ? Self.steadyBodyHeight : nil, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The wash changes by opacity: the new state's colour fades in over the old one's.
            bandFill.id(kind).transition(Self.crossFade)
        }
    }

    /// One state's content fades out as the next fades in. Opacity only, so it is the same with
    /// Reduce Motion; nothing slides and no size is animated.
    private static let crossFade = AnyTransition.opacity.animation(Theme.Motion.fade)

    /// The room the ready card's two lines take; the loading sentence and its track fit in it.
    private static let steadyBodyHeight: CGFloat = 46

    private var stateLine: some View {
        HStack(spacing: 6) {
            if kind == .loading, copy.load == nil, !isSnapshot {
                // Loading with no stages to show (a download just finished): something that moves.
                // With stages the track below is what moves, and this is the dot again.
                ProgressView().controlSize(.mini).tint(tint).frame(width: 12, height: 12)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(copy.stateWord.uppercased())
                .font(Theme.Font.eyebrow)
                .tracking(0.8)
                .foregroundStyle(kind == .ready ? Theme.phosphor : Theme.textSecondary)
        }
        // The headline under it says the same thing in a sentence; one is enough to hear.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var blockedBody: some View {
        Text(copy.detail)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
        if let additionalDetail {
            Text(additionalDetail).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let load = copy.load {
            LoadStageTrack(display: load).padding(.top, Theme.Space.xs)
        }
        if let progress = copy.progress {
            HeroProgressBar(fraction: progress, label: copy.progressLine)
                .padding(.top, Theme.Space.xs)
        } else if let line = copy.progressLine {
            Text(line).font(Theme.Font.data).foregroundStyle(Theme.textSecondary)
        }
        if let note = copy.note {
            Text(note)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let fixTitle = copy.fixTitle {
            Button(fixTitle, action: onFix)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, Theme.Space.xs)
        }
        if let additionalFixTitle {
            Button(additionalFixTitle, action: onAdditionalFix)
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// The state's colour: green for ready (as every other "ready" mark in the app), ink for a
    /// transfer and purple for the model loading (docs/product/UI-ROUND-2026-09-28.md §3, C2).
    private var tint: Color {
        switch kind {
        case .ready: Theme.success
        case .warning: Theme.warning
        case .error: Theme.error
        case .downloading: Theme.textTertiary
        case .loading: Theme.working
        }
    }

    /// The band's surface: the lime wash that marks what is the person's own while ready,
    /// otherwise a faint wash of the state's colour so a blocked card reads differently at once.
    private var bandFill: Color {
        switch kind {
        case .ready: Theme.phosphorTint
        case .warning, .error: tint.opacity(0.07)
        case .downloading: Theme.bgSunken.opacity(0.7)
        case .loading: Theme.workingTint
        }
    }
}

/// "Hold [fn] in any app and talk.", the key drawn as a key cap between the words, then the
/// hands-free line.
private struct HowToStartLines: View {
    let lines: [DictationHeroCopy.KeyLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.sentence) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.before).fixedSize(horizontal: false, vertical: true)
                    if let key = line.key {
                        KeyCap(label: key, size: 11)
                        Text(line.after).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.sentence)
            }
        }
        .font(Theme.Font.body)
        .foregroundStyle(Theme.textSecondary)
    }
}

/// The person's dictation key at the size of a real key: lime and lit while dictation is ready,
/// an unlit outline while it is not, so the key itself says whether pressing it will work.
private struct DictationKeyCap: View {
    let glyph: String
    let isLive: Bool
    @Environment(\.colorScheme) private var scheme

    private static let side: CGFloat = 68
    private static let depth: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        Text(glyph)
            .font(.system(size: glyph.count > 2 ? 20 : 26, weight: .semibold, design: .rounded))
            .foregroundStyle(isLive ? Theme.onPhosphor : Theme.textTertiary)
            .padding(.horizontal, Theme.Space.m)
            .frame(minWidth: Self.side, minHeight: Self.side)
            .background {
                if isLive {
                    // The key's side, then its face: a pressable object, not a flat chip.
                    shape.fill(Theme.phosphorFill).brightness(-0.2).offset(y: Self.depth)
                    shape.fill(Theme.phosphorFill)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                } else {
                    shape.fill(Theme.bgSunken)
                    shape.strokeBorder(Theme.textTertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .padding(.bottom, Self.depth)
            .liveGlow(isLive, radius: 14, scheme: scheme)
            .accessibilityHidden(true)
    }
}

/// A transfer's progress as a thin ink bar with its bytes-and-time line. Ink, not lime or
/// purple: a download is neither the person speaking nor the model working.
private struct HeroProgressBar: View {
    let fraction: Double
    let label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textTertiary.opacity(0.22))
                    Capsule().fill(Theme.textSecondary)
                        .frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 5)
            .frame(maxWidth: 360)
            if let label {
                Text(label).font(Theme.Font.data).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue(label ?? "\(Int(fraction * 100)) percent")
    }
}

/// The card's lower band (`HomeCardContent`): the last dictation with Copy and Open in History;
/// before the first one, the sentence to try; and while the app lock is on, no words at all,
/// one line saying so and Unlock.
private struct LastDictationBand: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let content: HomeCardContent
    let isReady: Bool
    let triggerGlyph: String
    let onCopy: (String) -> Void
    let onOpenInHistory: (Int64) -> Void
    let onUnlock: () -> Void
    @State private var isExpanded = false
    @State private var copied = false
    /// Puts "Copied" back to "Copy"; a second Copy restarts it instead of being cut short.
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                // Before the first dictation, with dictation ready, the band is an invitation.
                Eyebrow(content == .tryIt ? HomeFeedCopy.tryItTitle : HomeFeedCopy.lastDictationTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.s)
                if let last = content.last {
                    Text(Self.origin(last))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            switch content {
            case .locked:
                locked
            case .last(let last):
                words(last)
                actions(last)
            case .tryIt:
                tryIt
            case .waiting:
                Text(HomeFeedCopy.lastEmptyWaiting)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A new dictation starts folded and un-copied; so does the card after a lock.
        .onChange(of: content.last?.id) { _, _ in
            isExpanded = false
            copied = false
        }
    }

    /// No dictated words while the app lock is on: what is hidden, and the way to see it.
    private var locked: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(HomeFeedCopy.lockedMessage, systemImage: "lock.fill")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(HomeFeedCopy.unlockTitle, action: onUnlock)
                .buttonStyle(SecondaryButtonStyle())
                .help("Unlock Hushy to see your dictations")
                .accessibilityLabel("Unlock Hushy")
        }
    }

    /// "Mail · Today, 3:12 PM", or the time alone when no app was recorded.
    private static func origin(_ last: HomeLastDictation) -> String {
        [last.appName, last.whenLabel].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func words(_ last: HomeLastDictation) -> some View {
        Text(last.text)
            .font(.system(size: 17))
            .lineSpacing(5)
            .foregroundStyle(last.hasWords ? Theme.textPrimary : Theme.textTertiary)
            .lineLimit(last.isLong && !isExpanded ? HomeLastDictation.collapsedLineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
            .modifier(SelectableText(isEnabled: !isSnapshot && last.hasWords))
        if let note = last.note {
            Label(note, systemImage: "info.circle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actions(_ last: HomeLastDictation) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let text = last.copyText {
                copyButton(text)
            }
            if let id = last.id {
                Button("Open in History") { onOpenInHistory(id) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Open this dictation in History")
            }
            Spacer(minLength: Theme.Space.s)
            if last.isLong {
                Button(isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.phosphor)
                    .accessibilityLabel(isExpanded ? "Show less of the last dictation" : "Show all of the last dictation")
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Copy is the card's one lime button while dictation is ready; while it is blocked the fix
    /// above is, and Copy steps back to the quiet style.
    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        let button = Button(copied ? "Copied" : "Copy") { copy(text) }
            .help("Copy the last dictation")
            .accessibilityLabel(copied ? "Copied" : "Copy the last dictation")
        if isReady {
            button.buttonStyle(PrimaryButtonStyle())
        } else {
            button.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func copy(_ text: String) {
        onCopy(text)
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    /// The sentence to say, set like a dictation would be, and what happens when it is said.
    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("“\(HomeFeedCopy.tryItSentence)”")
                .font(.system(size: 17))
                .lineSpacing(5)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(HomeFeedCopy.tryItMessage(triggerGlyph: triggerGlyph))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text selection is AppKit-backed, which `ImageRenderer` cannot draw; snapshots get plain text.
private struct SelectableText: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
