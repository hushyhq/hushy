import MurmurCore
import SwiftUI

/// Home says what Hushy is: a dictation app. In order: one quiet line (greeting and date); the
/// dictation card (`HomeDictationHero`: is dictation ready, how to start with the person's own
/// key, and the most recent dictation with Copy and Open in History); the "Today" feed mixing
/// dictations, notes and voice actions, with the most recent earlier day under it (between the card and
/// the feed, at most one small tip, `HomeTip`); and a flat
/// foot of reference (`HomeFootnotes`: the day's trace, the week, the voice-action hint).
/// Recording a note lives in the sidebar and the Assistant in the main window's right-hand pane
/// on every section (`MainView`); neither is part of Home. Clicking a dictation in the feed
/// opens it in a Quick Look panel (`DictationQuickLook`).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotHomeSelection) private var snapshotHomeSelection
    @Environment(\.snapshotHomeFeed) private var snapshotFeed
    @Environment(\.snapshotUsageNotice) private var snapshotUsageNotice
    @Environment(\.snapshotDictateWarning) private var snapshotDictateWarning
    @Environment(\.snapshotAppLocked) private var snapshotAppLocked
    @State private var quickLook = DictationQuickLook()
    @FocusState private var feedFocused: Bool
    /// Home's one-time usage-numbers notice. Decided when Home appears, then kept until the person
    /// answers it, so opening the sheet (which marks it seen) does not pull it out from under the sheet.
    @State private var showUsageNotice = false
    @State private var showUsageSheet = false

    /// Home's own copy of the expander state. What is read is always `expansion`, which starts
    /// fresh when the day has changed, so yesterday's "Show 12 more" never carries into today.
    @State private var expansionState = HomeExpansion(day: .distantPast)

    private var clock: DayClock { model.dayClock }

    private var expansion: HomeExpansion {
        snapshotFeed?.expansion ?? expansionState.rolledOver(to: clock.day)
    }

    /// What Home shows: today's entries (capped) and the most recent earlier day. A pure
    /// function of the library, the clock's now and the calendar (`HomeTimeline.select`), so a
    /// day change redraws it. Snapshot mode swaps in fixture data.
    private var selection: HomeTimelineSelection {
        if let snapshotFeed { return snapshotFeed.selection }
        let library = model.library
        return HomeTimeline.select(
            dictations: library.dictations, notes: FeatureFlags.meetings ? library.notes : [], actions: library.actionRecords,
            now: clock.now, calendar: clock.calendar)
    }

    private var calendar: Calendar { snapshotFeed?.calendar ?? clock.calendar }

    /// The app lock is on (Settings → Privacy & security). Home is not behind `LockGate`, since
    /// dictation's readiness must stay visible, so it hides every dictated word itself: the
    /// card's last dictation, the Today feed, the earlier day, Quick Look and the day's trace.
    private var isLocked: Bool { snapshotAppLocked || model.appLock.isLocked }

    /// The highlighted row: the Quick Look selection, or, in snapshot mode only, the feed's first
    /// dictation, so the selected-row state can be captured without a live click.
    private func highlightedID(visible: [Int64]) -> Int64? {
        if let id = quickLook.currentID { return id }
        return snapshotHomeSelection ? visible.first : nil
    }

    var body: some View {
        let selection = selection
        let visible = isLocked ? [] : selection.visibleDictationIDs(expansion: expansion, calendar: calendar)
        feed(selection: selection, selectedID: highlightedID(visible: visible))
            .background(Theme.bgBase)
            // Quick Look's Up/Down order is exactly what is on screen, expanders included.
            .onChange(of: visible, initial: true) { _, ids in quickLook.order = { ids } }
            .onDisappear { quickLook.close() }
            // A Quick Look left open would keep showing a dictation after the lock comes on.
            .onChange(of: isLocked) { _, locked in
                guard locked else { return }
                quickLook.close()
                quickLook.select(nil)
            }
            .onAppear { showUsageNotice = snapshotUsageNotice || model.usageMetrics.needsNotice }
            .sheet(isPresented: $showUsageSheet, onDismiss: { showUsageNotice = false }) { UsageNumbersSheet() }
    }

    private func feed(selection: HomeTimelineSelection, selectedID: Int64?) -> some View {
        content(selection: selection, selectedID: selectedID)
            .modifier(HomeScroll(isSnapshot: isSnapshot))
            // Pinned to the window's bottom edge, outside the scroll, like a status line.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PrivacyFooter()
                    .padding(.horizontal, Theme.Space.xxl + 8)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                    .background(Theme.bgBase)
            }
            .frame(maxWidth: .infinity)
    }

    /// The dictations Home is showing: the library's, or a snapshot fixture's.
    private var dictations: [Dictation] { snapshotFeed?.dictations ?? model.library.dictations }

    private var now: Date { snapshotFeed?.now ?? clock.now }

    private func content(selection: HomeTimelineSelection, selectedID: Int64?) -> some View {
        // Computed once per pass: the card and the foot both read it.
        let readiness = model.dictationReadiness(forcingKeyConflict: snapshotDictateWarning)
        // A plain VStack, not Lazy: LazyVStack keeps its first measurement of a child whose
        // height later changes, leaving the scroll height stale — the last rows ended up stuck
        // under the pinned footer, unscrollable and unclickable.
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if showUsageNotice { usageNotice }
            // The lead: the greeting line sits close above the card it introduces.
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HomeDayLine(name: model.settings.userName, now: now, calendar: calendar)
                HomeDictationHero(
                    status: readiness, dictations: dictations, now: now, calendar: calendar, isLocked: isLocked)
            }
            if let tip = HomeTipContext.make(dictations: dictations, settings: model.settings, now: now).next {
                HomeTipCard(
                    tip: tip, triggerGlyph: model.settings.triggerKey.glyph,
                    onAction: { model.section = .style },
                    onDismiss: {
                        withAnimation(Theme.Motion.fade) { model.settings.dismissedHomeTips.insert(tip.rawValue) }
                    })
                    .id(tip)
                    .transition(.opacity)
            }
            TodayFeed(
                selection: selection, expansion: expansion, calendar: calendar,
                selectedDictationID: selectedID, onSelectDictation: open,
                onExpansionChange: { expansionState = $0 },
                numbers: HomeTodayNumbers.make(
                    dictations: dictations, now: now, calendar: calendar,
                    typingWPM: model.settings.effectiveTypingWPM),
                isLocked: isLocked)
                .frame(maxWidth: .infinity, alignment: .top)
                .focusable()
                .focused($feedFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) { handleSpace() }
                .onKeyPress(.escape) { handleEscape() }
                .onKeyPress(.upArrow) { moveSelection(.previous) }
                .onKeyPress(.downArrow) { moveSelection(.next) }
            HomeFootnotes(
                dictations: dictations, now: now, calendar: calendar,
                triggerGlyph: model.settings.triggerKey.glyph,
                actionKeyCap: model.settings.effectiveActionTrigger.keyCap,
                days: model.library.insights.days, currentStreak: model.library.insights.currentStreak,
                showsActivity: !isLocked,
                showsTryIt: HomeLastDictation.pick(from: dictations) != nil && readiness.reason == .ready)
                .padding(.top, Theme.Space.s)
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, Theme.Space.xxl + 8)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: 1200, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var usageNotice: some View {
        UsageNumbersNotice(
            isOn: Binding(get: { model.settings.shareUsageNumbers }, set: { model.settings.shareUsageNumbers = $0 }),
            onSeeWhatsSent: { showUsageSheet = true },
            onOK: {
                model.settings.usageNumbersNoticeSeen = true
                showUsageNotice = false
            })
    }

    /// A row click opens (or, on the open row, closes) its Quick Look, and gives the feed
    /// keyboard focus so Space and the arrows work next.
    private func open(_ id: Int64) {
        feedFocused = true
        quickLook.toggle(id, model: model)
    }

    /// Space on the selected row opens its Quick Look (Space inside the panel closes it).
    private func handleSpace() -> KeyPress.Result {
        guard !isLocked, let id = quickLook.currentID else { return .ignored }
        quickLook.toggle(id, model: model)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        guard quickLook.currentID != nil else { return .ignored }
        quickLook.select(nil)
        return .handled
    }

    private func moveSelection(_ direction: QuickLookNavigation.Direction) -> KeyPress.Result {
        guard !isLocked else { return .ignored }
        let order = selection.visibleDictationIDs(expansion: expansion, calendar: calendar)
        guard let next = QuickLookNavigation.neighbor(of: quickLook.currentID, inOrder: order, direction: direction) else {
            return .ignored
        }
        quickLook.select(next)
        return .handled
    }
}

private struct HomeScroll: ViewModifier {
    let isSnapshot: Bool

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            ScrollView { content }.scrollContentBackground(.hidden)
        }
    }
}
