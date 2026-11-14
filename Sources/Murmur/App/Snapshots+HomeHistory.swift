import MurmurCore
import SwiftUI

/// The Home dictation card and History's header and modes (interface round, 2026-10-11).
/// Invented text only; Home's states use a fixed moment (Monday 5 Oct 2026, 3:30 pm).
///
/// - `home-hero-ready`: dictation ready, with a last dictation and today's feed.
/// - `home-hero-empty`: ready, nothing dictated yet.
/// - `home-hero-downloading`: the speech model on its way, nothing dictated yet.
/// - `home-hero-loading`: the speech model loading into memory, as at every launch, midway through
///   its stages (`lp-*` has the card alone in each loading state).
/// - `home-hero-microphone`, `home-hero-accessibility`: a missing permission.
/// - `home-hero-long`: one long last dictation (about 120 words), folded.
/// - `home-locked`: the app lock on, with dictations that must not show (the Assistant pane
///   beside it is locked too); `search-locked`: the ⌘K palette while locked.
/// - `lock-pill-paste`, `lock-pill-copy`: the pill's one line when paste last or copy last is
///   pressed while locked; `lock-card-untouched`, `lock-card-copied`: a not-pasted card while
///   locked, with its words and Copy and neither shortcut named.
/// - `history-scope-today`, `history-scope-day`, `history-scope-all`: Today (the default), one
///   earlier day, and All dates.
/// - `history-selecting`: several dictations checked; `history-selecting-none`: just entered.
extension Snapshots {
    /// Before anything renders: dictations on earlier days, so "All dates" has more than today
    /// to show, and dictation pinned ready, so every page shows Home's card in one known state
    /// instead of this machine's real permissions.
    static func prepareHomeHistory(model: AppModel) {
        for dictation in HomeHistoryFixtures.earlierDays(now: Date(), calendar: .current) {
            _ = try? model.store.save(dictation)
        }
        model.modelStatus.pinForSnapshot(.ready)
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
    }

    static func renderHomeHistory(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        await renderHomeHero(model: model, scheme: scheme, size: size, directory: directory)
        await renderHistoryModes(model: model, scheme: scheme, size: size, directory: directory)
        await renderLockedPill(scheme: scheme, directory: directory)
    }

    /// The pill while the app lock is on. Paste last and copy last refuse in one line, and a
    /// card for a dictation that was just not pasted keeps its words and Copy but names neither
    /// shortcut (compare `rec-card-short` and `rec-card-long-untouched`).
    private static func renderLockedPill(scheme: ColorScheme, directory: URL) async {
        func lockedPill(_ state: PillState, text: String = "") -> PillModel {
            let pill = PillModel()
            pill.showWhenIdle = true
            pill.isAppLocked = { true }
            pill.present(state, text: text)
            return pill
        }
        func shot(_ name: String, _ pill: PillModel, height: CGFloat) async {
            await capture(
                PillView(model: pill).frame(height: height)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: name, scheme: scheme, size: CGSize(width: 600, height: height + 56),
                directory: directory, fixedSize: true)
        }
        let words = "Remind me to send Dana the pricing page before Friday."
        await shot("lock-pill-paste", lockedPill(.error(LastTranscriptShortcut.paste.lockedNotice)), height: 64)
        await shot("lock-pill-copy", lockedPill(.error(LastTranscriptShortcut.copy.lockedNotice)), height: 64)
        await shot("lock-card-untouched", lockedPill(.noField(.offerCopy), text: words), height: 170)
        await shot("lock-card-copied", lockedPill(.noField(.copiedAutomatically), text: words), height: 170)
    }

    private static func renderHomeHero(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let calendar = Calendar.current
        let fresh = HomeExpansion(day: calendar.startOfDay(for: HomeFixtures.now(calendar)))
        let few = HomeFixtures.feed(calendar: calendar, today: .few, expansion: fresh)
        let nothing = SnapshotHomeFeed(
            dictations: [], notes: [], actions: [], now: few.now, calendar: calendar, expansion: fresh)
        let long = SnapshotHomeFeed(
            dictations: few.dictations + [HomeHistoryFixtures.longDictation(at: few.now.addingTimeInterval(-6 * 60))],
            notes: few.notes, actions: few.actions, now: few.now, calendar: calendar, expansion: fresh)
        model.section = .home
        model.settings.sidebarCollapsed = false
        // Taller than a page, like the other Home states: `ImageRenderer` can't scroll.
        let tall = CGSize(width: size.width, height: 1500)
        func home(_ name: String, _ feed: SnapshotHomeFeed) async {
            await capture(
                MainView().environment(model).environment(\.snapshotHomeFeed, feed),
                name: name, scheme: scheme, size: tall, directory: directory)
        }

        await home("home-hero-ready", few)
        await home("home-hero-empty", nothing)
        await home("home-hero-long", long)
        // Locked: the same feed, none of its words, and the Assistant pane beside it hidden
        // too. The lock itself is never touched; the environment says "locked".
        await capture(
            MainView().environment(model).environment(\.snapshotHomeFeed, few).environment(\.snapshotAppLocked, true),
            name: "home-locked", scheme: scheme, size: tall, directory: directory)
        // A sheet can't be drawn by `ImageRenderer`; render the palette's content directly.
        await capture(
            SearchPalette().environment(model).environment(\.snapshotAppLocked, true),
            name: "search-locked", scheme: scheme, size: CGSize(width: 560, height: 240), directory: directory,
            fixedSize: true)

        let expected = SpeechEngine.expectedDownloadBytes(for: .v2)
        let downloading = ModelDownloadProgress(
            fraction: 0.43, expectedBytes: expected, completedFiles: 1, totalFiles: 4, estimatedSecondsRemaining: 230)
        model.modelStatus.pinForSnapshot(.downloading(downloading.fraction), download: downloading)
        await home("home-hero-downloading", nothing)
        // Midway through loading, on a Mac that usually takes about five seconds.
        model.modelStatus.pinForSnapshot(.loading, loadProgress: SpeechLoadProgress(
            startedAt: few.now.addingTimeInterval(-2.5), usual: [.loading: 4, .warming: 1]))
        await home("home-hero-loading", few)
        model.modelStatus.pinForSnapshot(.ready)

        model.permissions.pinForSnapshot(microphone: .denied)
        await home("home-hero-microphone", few)
        model.permissions.pinForSnapshot(microphone: .granted)

        model.permissions.pinForSnapshot(accessibility: .denied)
        await home("home-hero-accessibility", few)
        model.permissions.pinForSnapshot(accessibility: .granted)
    }

    private static func renderHistoryModes(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        model.section = .history
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        await capture(MainView().environment(model), name: "history-scope-today", scheme: scheme, size: size, directory: directory)
        await capture(
            MainView().environment(model).environment(\.snapshotHistoryDateRange, .custom(start: yesterday, end: yesterday)),
            name: "history-scope-day", scheme: scheme, size: size, directory: directory)
        // Taller: several days of rows, laid out flat.
        let tall = CGSize(width: size.width, height: 1400)
        await capture(
            MainView().environment(model).environment(\.snapshotHistoryAllDates, true),
            name: "history-scope-all", scheme: scheme, size: tall, directory: directory)
        await capture(
            MainView().environment(model).environment(\.snapshotHistorySelecting, true),
            name: "history-selecting", scheme: scheme, size: size, directory: directory)
        await capture(
            MainView().environment(model).environment(\.snapshotHistorySelecting, true)
                .environment(\.snapshotHistorySelectionCount, 0),
            name: "history-selecting-none", scheme: scheme, size: size, directory: directory)
        model.section = .home
    }
}

enum HomeHistoryFixtures {
    private static let apps: [(id: String, name: String)] = [
        ("com.apple.mail", "Mail"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.Notes", "Notes"), ("com.apple.Safari", "Safari"),
    ]

    /// Invented dictations on yesterday, three days ago and eight days ago, so History's
    /// "All dates" and Home's earlier-day row have something real to show.
    static func earlierDays(now: Date, calendar: Calendar) -> [Dictation] {
        let today = calendar.startOfDay(for: now)
        let rows: [(daysBack: Int, hour: Int, minute: Int, app: Int, text: String)] = [
            (1, 16, 40, 0, "Can you send the revised budget before noon?"),
            (1, 16, 32, 0, "Thanks, that works for me."),
            (1, 11, 5, 1, "Sounds good, see you at the stand-up."),
            (3, 14, 20, 2, "We should cut the second section and keep the chart."),
            (3, 14, 12, 2, "Remind the team that the draft is due on Friday."),
            (8, 10, 45, 3, "Please check the spelling of the client's name."),
            (8, 9, 30, 0, "I'll follow up with the vendor tomorrow."),
        ]
        return rows.compactMap { row in
            guard let day = calendar.date(byAdding: .day, value: -row.daysBack, to: today),
                  let date = calendar.date(bySettingHour: row.hour, minute: row.minute, second: 0, of: day)
            else { return nil }
            let app = apps[row.app]
            return Dictation(
                createdAt: date, rawText: row.text.lowercased(), text: row.text, appBundleID: app.id, appName: app.name,
                durationSeconds: 4, status: .inserted)
        }
    }

    /// One long dictation, about 120 words, for the card's folded state.
    static func longDictation(at date: Date) -> Dictation {
        let text = """
            Hi Dana, thanks for sending the plan over. I read it this morning and I think the overall shape is right, \
            so most of what follows is small. First, the timeline. Two weeks for the review feels tight given that half \
            the team is out the week after next, so I would move the deadline to the twenty-third and tell people now \
            rather than later. Second, the budget table. The totals are fine, but the travel line still shows last \
            year's number, and I would rather we fix it before it goes to finance. Third, the summary at the top. It is \
            clear, but it buries the one decision we need from them, so please put that in the first sentence. \
            Everything else can go out as it is. Let's talk on Thursday.
            """
        return Dictation(
            id: 900, createdAt: date, rawText: text.lowercased(), text: text, appBundleID: "com.apple.mail", appName: "Mail",
            durationSeconds: 52, status: .inserted)
    }
}
