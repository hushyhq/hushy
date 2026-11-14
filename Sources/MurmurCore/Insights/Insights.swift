import Foundation

/// Where a dictation went, grouped for the Insights breakdown.
public enum AppCategory: String, CaseIterable, Sendable, Codable {
    case aiPrompts, email, workMessages, personalMessages, documents, code, other

    public var title: String {
        switch self {
        case .aiPrompts: "AI prompts"
        case .email: "Email"
        case .workMessages: "Work messages"
        case .personalMessages: "Personal messages"
        case .documents: "Documents"
        case .code: "Code"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .aiPrompts: "sparkles"
        case .email: "envelope"
        case .workMessages: "bubble.left.and.text.bubble.right"
        case .personalMessages: "message"
        case .documents: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "square.grid.2x2"
        }
    }

    /// Browsers host web apps (Gmail, Slack, WhatsApp Web…); their window title tells us which.
    static let browsers = [
        "com.google.chrome", "com.apple.safari", "company.thebrowser.browser", "com.brave.browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "app.zen-browser", "com.vivaldi.vivaldi", "com.operasoftware.opera",
    ]

    /// Web apps recognised from a browser window title, in priority order.
    static let webApps: [(AppCategory, [String])] = [
        (.email, ["gmail", "inbox", "outlook", "superhuman", "proton mail", "fastmail", "yahoo mail", "hey.com"]),
        (.workMessages, ["slack", "microsoft teams", "linear", "google chat", "github", "gitlab"]),
        (.personalMessages, ["whatsapp", "messenger", "telegram", "discord", "instagram"]),
        (.aiPrompts, ["chatgpt", "claude", "gemini", "perplexity"]),
        (.documents, ["google docs", "notion", "confluence", "- google docs", "dropbox paper"]),
    ]

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return browsers.contains { id.hasPrefix($0) }
    }

    /// Classifies by app, and for browsers by the active tab's window title. A browser is `.code`
    /// only when the tab is a web code editor (vscode.dev, github.dev, Codespaces, Replit,
    /// StackBlitz, CodeSandbox, JSFiddle, JupyterLab, Colab, GitHub's file editor; see
    /// `WebCodeEditor`), because the cursor is in code (founder, 2026-10-05). Every other tab is
    /// prose (founder, 2026-10-04): a GitHub or GitLab tab is a PR description or a review
    /// comment, so it is a work message (spoken technical tokens are still converted there).
    /// Editors and terminals stay `.code`.
    public static func classify(bundleID: String?, windowTitle: String?) -> AppCategory {
        if isBrowser(bundleID), let rawTitle = windowTitle {
            // Before the web-app table: "[GitHub]" in a github.dev title would read as GitHub.
            if WebCodeEditor.matches(windowTitle: rawTitle) { return .code }
            let title = rawTitle.lowercased()
            for (category, needles) in webApps where needles.contains(where: { title.contains($0) }) {
                return category
            }
            // A call in a tab (Google Meet, the Zoom web client, Webex) is work. Checked after the table above, so a
            // document or note about a meeting stays a document; see `MeetingTab` for the exact shapes.
            if MeetingTab.isCall(windowTitle: rawTitle) { return .workMessages }
        }
        let category = classify(bundleID: bundleID)
        return category == .code && isBrowser(bundleID) ? .other : category
    }

    public static func classify(bundleID: String?) -> AppCategory {
        guard let id = bundleID?.lowercased() else { return .other }
        let table: [(AppCategory, [String])] = [
            (.aiPrompts, ["com.openai.chat", "com.anthropic.claude", "com.openai.codex", "perplexity", "chatgpt"]),
            // Meeting apps are work. Before email: Webex's identifier (Cisco-Systems.Spark) contains "spark".
            (.workMessages, ["us.zoom.xos", "cisco-systems.spark", "com.webex", "com.cisco.webex"]),
            (.email, ["com.apple.mail", "com.readdle.smartemail", "superhuman", "com.microsoft.outlook", "spark", "mimestream"]),
            (.workMessages, ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "linear"]),
            (.personalMessages, ["com.apple.mobilesms", "whatsapp", "telegram", "signal", "messenger", "discord"]),
            (.documents, ["com.apple.notes", "notion", "com.apple.iwork.pages", "com.microsoft.word", "obsidian", "craft", "bear", "com.apple.textedit"]),
            (.code, ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "cursor", "com.exafunction.windsurf", "windsurf", "com.apple.dt.xcode", "zed", "com.apple.terminal", "iterm", "ghostty", "warp", "jetbrains",
                    // Added 2026-10-06 (task 112) so no tone is ever applied in these: editors and terminals
                    // that fell through to "other" (Sublime Text, Alacritty and the rest).
                    "com.sublimetext", "org.alacritty", "net.kovidgoyal.kitty", "wezterm", "co.zeit.hyper",
                    "com.panic.nova", "com.barebones.bbedit", "com.macromates.textmate", "com.google.android.studio",
                    "vscodium", "org.gnu.emacs", "org.vim.macvim", "com.github.atom", "com.coteditor", "app.codeedit", "org.tabby"]),
        ]
        for (category, needles) in table where needles.contains(where: { id.contains($0) }) {
            return category
        }
        // An app the table does not know, which the latest look at the installed apps placed (a social app, or
        // a terminal or editor that must never be given a tone). Empty until that look has finished.
        return DiscoveredAppKinds.category(forLowercasedID: id) ?? .other
    }
}

public struct Insights: Sendable, Equatable {
    public struct DayCount: Sendable, Equatable, Hashable {
        public let day: Date
        public let words: Int
    }

    public struct AppShare: Sendable, Equatable, Hashable {
        public let bundleID: String
        public let name: String
        public let words: Int
        public let fraction: Double
    }

    public struct CategoryShare: Sendable, Equatable, Hashable {
        public let category: AppCategory
        public let words: Int
        public let count: Int
        public let fraction: Double
    }

    public let totalWords: Int
    public let totalDictations: Int
    public let averageWPM: Int
    public let fixes: Int
    public let currentStreak: Int
    public let longestStreak: Int
    /// Minutes saved versus typing at `typingWPM`.
    public let minutesSaved: Int
    public let days: [DayCount]
    public let categories: [CategoryShare]
    public let appsUsed: Int
    /// Share of dictations left exactly as typed (nil until some have been measured).
    public var editFreeRate: Double? = nil
    public var editsMeasured = 0
    /// The same two numbers for the last seven days, today included (`weekStart(now:calendar:)`).
    public var weekEditsKept = 0
    public var weekEditsMeasured = 0
    /// Most-used apps by words dictated.
    public var topApps: [AppShare] = []
    /// Total time spent speaking, for "saved vs typing" at the user's own typing speed.
    public var speakingSeconds: Double = 0

    /// Minutes saved versus typing the same words at `typingWPM` (the user's measured speed,
    /// or the average-typist default).
    public func minutesSaved(typingWPM: Double) -> Int {
        Int((Self.secondsSaved(words: totalWords, speakingSeconds: speakingSeconds, typingWPM: typingWPM) / 60).rounded())
    }

    /// Seconds saved by dictating `words` in `speakingSeconds` instead of typing them at
    /// `typingWPM`. Never negative (a slow dictation saves nothing, it doesn't cost time). The
    /// one formula behind both the lifetime figure (Insights) and the per-day one (Home), so
    /// the two can't drift apart.
    public static func secondsSaved(words: Int, speakingSeconds: Double, typingWPM: Double) -> Double {
        guard typingWPM > 0, words > 0 else { return 0 }
        return max(0, Double(words) / typingWPM * 60 - speakingSeconds)
    }

    /// Today's words and speaking time, from the same dictations `compute` counts (cancelled
    /// and failed ones excluded), so Home's "today" stats agree with the lifetime ones.
    public static func todayTotals(
        from dictations: [Dictation], now: Date = Date(), calendar: Calendar = .current
    ) -> (words: Int, speakingSeconds: Double) {
        let today = calendar.startOfDay(for: now)
        let counted = dictations.filter {
            $0.status != .cancelled && $0.status != .failed && calendar.startOfDay(for: $0.createdAt) == today
        }
        return (counted.reduce(0) { $0 + $1.wordCount }, counted.reduce(0) { $0 + $1.durationSeconds })
    }

    /// A stat-tile value for a saved-time figure: "—" for nothing yet (never a meaningless
    /// "0 min"), whole seconds under a minute, whole minutes under an hour, then hours to one
    /// decimal ("1.5 h").
    public static func savedTimeValue(seconds: Double) -> String {
        guard seconds >= 1 else { return "—" }
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds < 60 { return "\(wholeSeconds) s" }
        let wholeMinutes = Int((seconds / 60).rounded())
        if wholeMinutes < 60 { return "\(wholeMinutes) min" }
        let hours = seconds / 3_600
        let rounded = (hours * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) h" : String(format: "%.1f h", rounded)
    }

    /// The first moment of the seven-day window that ends today: the start of the day six days ago.
    public static func weekStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    /// Fewer measured dictations than this show as "k of n", because a percentage of a handful is noise.
    public static let minMeasuredForWeekRate = 5

    /// "You kept 86% of dictations as typed this week": the person's own number, private to this Mac.
    /// Nil until at least one dictation of the week has been checked.
    public static func keptThisWeekLine(kept: Int, measured: Int) -> String? {
        guard measured > 0, kept >= 0, kept <= measured else { return nil }
        guard measured >= minMeasuredForWeekRate else {
            return "You kept \(kept) of \(measured) checked dictations as typed this week"
        }
        return "You kept \(Int((Double(kept) / Double(measured) * 100).rounded()))% of dictations as typed this week"
    }

    public var keptThisWeekLine: String? { Self.keptThisWeekLine(kept: weekEditsKept, measured: weekEditsMeasured) }

    public static let typingWPM = 40.0
    /// The app's own bundle id: practice dictations in onboarding shouldn't rank as an app.
    /// Includes the pre-rename id too, so dictations recorded before the Murmur -> Hushy
    /// rename (see .claude/DECISIONS.md) are still excluded after upgrading.
    public static let ownBundleID = "app.hushy.Hushy"
    public static let ownBundleIDs: Set<String> = ["app.hushy.Hushy", "app.murmur.Murmur"]

    public static let empty = Insights(
        totalWords: 0, totalDictations: 0, averageWPM: 0, fixes: 0, currentStreak: 0, longestStreak: 0,
        minutesSaved: 0, days: [], categories: [], appsUsed: 0)

    public static func compute(
        from dictations: [Dictation], now: Date = Date(), calendar: Calendar = .current
    ) -> Insights {
        let counted = dictations.filter { $0.status != .cancelled && $0.status != .failed }
        guard !counted.isEmpty else { return .empty }

        let totalWords = counted.reduce(0) { $0 + $1.wordCount }
        let totalSeconds = counted.reduce(0) { $0 + $1.durationSeconds }
        let wpm = totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0
        let typingMinutes = Double(totalWords) / typingWPM
        let saved = max(0, typingMinutes - totalSeconds / 60)

        var perDay: [Date: Int] = [:]
        for item in counted {
            perDay[calendar.startOfDay(for: item.createdAt), default: 0] += item.wordCount
        }
        let streaks = Self.streaks(activeDays: Set(perDay.keys), now: now, calendar: calendar)
        let weekStart = Self.weekStart(now: now, calendar: calendar)
        let thisWeek = counted.filter { $0.createdAt >= weekStart && $0.editState != nil }

        var perCategory: [AppCategory: (words: Int, count: Int)] = [:]
        for item in counted {
            let category = AppCategory.classify(bundleID: item.appBundleID)
            let current = perCategory[category] ?? (0, 0)
            perCategory[category] = (current.words + item.wordCount, current.count + 1)
        }
        let categories = perCategory
            .map { CategoryShare(category: $0.key, words: $0.value.words, count: $0.value.count,
                                 fraction: Double($0.value.words) / Double(max(totalWords, 1))) }
            .sorted { $0.words > $1.words }

        return Insights(
            totalWords: totalWords,
            totalDictations: counted.count,
            averageWPM: Int(wpm.rounded()),
            fixes: counted.reduce(0) { $0 + $1.fixes },
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            minutesSaved: Int(saved.rounded()),
            days: perDay.map { DayCount(day: $0.key, words: $0.value) }.sorted { $0.day < $1.day },
            categories: categories,
            appsUsed: Set(counted.compactMap(\.appBundleID)).count,
            editFreeRate: EditVerdict.editFreeRate(counted),
            editsMeasured: counted.filter { $0.editState != nil }.count,
            weekEditsKept: thisWeek.filter { $0.editState == .kept }.count,
            weekEditsMeasured: thisWeek.count,
            topApps: topApps(counted, totalWords: totalWords),
            speakingSeconds: totalSeconds
        )
    }

    static func topApps(_ items: [Dictation], totalWords: Int) -> [AppShare] {
        var words: [String: (name: String, words: Int)] = [:]
        for item in items {
            guard let id = item.appBundleID, !Insights.ownBundleIDs.contains(id) else { continue }
            let current = words[id] ?? (item.appName ?? id, 0)
            words[id] = (current.name, current.words + item.wordCount)
        }
        return words.map { AppShare(bundleID: $0.key, name: $0.value.name, words: $0.value.words,
                                    fraction: Double($0.value.words) / Double(max(totalWords, 1))) }
            .sorted { $0.words > $1.words }
            .prefix(6)
            .map { $0 }
    }

    /// The current streak counts today, or yesterday if nothing has been dictated yet today.
    static func streaks(activeDays: Set<Date>, now: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let sorted = activeDays.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for day in sorted {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        let today = calendar.startOfDay(for: now)
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while activeDays.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }
}
