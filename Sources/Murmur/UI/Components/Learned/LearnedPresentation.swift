import Foundation
import MurmurCore

/// Pure rules and copy for the learn-from-corrections surfaces: which suggestion a dictation
/// shows, which terms the Today notice lists, and the sentences each row reads. No state and no
/// I/O, so every rule here is unit-tested (`LearnedPresentationTests`).
enum LearnedPresentation {
    // MARK: Selection

    /// Ready suggestions (fixed 2+ times) whose most recent fix came from `dictationID`, best
    /// first. Suggestions that aren't ready yet never surface in History: one fix is not
    /// enough to interrupt anyone (DECISIONS 2026-09-27, "proposed, never silent").
    static func historySuggestions(forDictation dictationID: Int64, in items: [LearnedItem]) -> [LearnedItem] {
        LearnedPersonalization.suggestions(items)
            .filter { $0.isReadySuggestion && $0.sourceDictationIDs.last == dictationID }
    }

    /// Terms the Today notice lists: terms that became active *by themselves* today (auto
    /// activation, never a term the user just added with ✓). Empty while
    /// `FeatureFlags.autoActivateLearnedTerms` is off (it defaults on): with the flag off,
    /// nothing activates without the user's tap, so there is nothing to announce.
    static func noticeTerms(
        in items: [LearnedItem], isAutoActivateOn: Bool, now: Date = Date(), calendar: Calendar = .current
    ) -> [LearnedItem] {
        guard isAutoActivateOn else { return [] }
        return items
            .filter { isAutoActivatedTerm($0) && $0.status == .active }
            .filter { item in item.activatedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
            .sorted { ($0.activatedAt ?? $0.lastSeenAt) < ($1.activatedAt ?? $1.lastSeenAt) }
    }

    /// A habit with enough evidence to ask about, that Hushy can apply once the person says yes.
    static func isOfferableHabit(_ item: LearnedItem) -> Bool {
        item.status == .candidate && item.isReadySuggestion && !item.confirmed && canUseHabit(item)
    }

    /// Habits Today may ask about, oldest first: each is asked once (`announced` marks it asked).
    static func habitOffers(in items: [LearnedItem]) -> [LearnedItem] {
        items.filter { isOfferableHabit($0) && !$0.announced }.sorted { ($0.lastSeenAt, $0.id ?? 0) < ($1.lastSeenAt, $1.id ?? 0) }
    }

    /// "In Slack you leave out greetings. Should Hushy do the same there?"
    static func habitQuestion(_ item: LearnedItem, appName: String) -> String? {
        styleSentence(item, appName: appName).map { "\($0). Should Hushy do the same there?" }
    }

    /// A term Hushy put into use on its own (not one the user confirmed).
    static func isAutoActivatedTerm(_ item: LearnedItem) -> Bool {
        item.kind == .term && !item.confirmed && item.activatedAt != nil
    }

    // MARK: Copy

    /// "once", "twice", "3 times".
    static func times(_ count: Int) -> String {
        switch count {
        case ...1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }

    /// The most recent way the recognizer misheard the term, if it differs from the term.
    static func heardAs(_ item: LearnedItem) -> String? {
        item.heardAs.last { $0.caseInsensitiveCompare(item.value) != .orderedSame }
    }

    /// The History suggestion as one plain sentence (VoiceOver reads this):
    /// "You corrected “Pria” to “Priya” twice. Add Priya to your dictionary?"
    static func suggestionSentence(_ item: LearnedItem) -> String {
        "\(correctionClause(item, arrow: "to")) \(suggestionQuestion(item))"
    }

    /// "You corrected “Pria” → “Priya” twice." (the visible form uses the arrow).
    static func correctionClause(_ item: LearnedItem, arrow: String = "→") -> String {
        let count = times(max(item.observations, 1))
        guard let heard = heardAs(item) else { return "You corrected “\(item.value)” \(count)." }
        return "You corrected “\(heard)” \(arrow) “\(item.value)” \(count)."
    }

    static func suggestionQuestion(_ item: LearnedItem) -> String {
        "Add \(item.value) to your dictionary?"
    }

    static func addedLine(_ item: LearnedItem) -> String {
        item.kind == .styleSignal ? "Using this habit in this app" : "Added \(item.value) to your dictionary"
    }
    static func dismissedLine(_ item: LearnedItem) -> String { "Won't suggest \(displayName(item)) again" }
    static func forgottenLine(_ item: LearnedItem) -> String { "Forgot \(displayName(item))" }

    /// "Learned from your edits: Priya, Kubernetes".
    static func noticeText(_ items: [LearnedItem]) -> String {
        "Learned from your edits: \(names(items))"
    }

    /// "Priya, Kubernetes" (list-formatted: "Priya and Kubernetes" reads worse in one line).
    static func names(_ items: [LearnedItem]) -> String {
        items.map(\.value).joined(separator: ", ")
    }

    /// Provenance for a list row: "heard as “Pria” · fixed twice · Slack, Notes". Apps come
    /// from the source dictations still in the library, most recent first, at most three.
    static func provenance(_ item: LearnedItem, appNames: [Int64: String]) -> String {
        var parts: [String] = []
        if let heard = heardAs(item) { parts.append("heard as “\(heard)”") }
        let fixes = (item.observations > 0 ? item.observations : item.sourceDictationIDs.count)
        if item.kind == .term, item.status == .active {
            parts.append(item.confirmed ? "added by you" : "learned after \(fixes) fixes")
        } else if fixes > 0 {
            parts.append("fixed \(times(fixes))")
        }
        let apps = sourceApps(item, appNames: appNames)
        if !apps.isEmpty { parts.append(apps.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Distinct app names of the item's source dictations, most recent first.
    static func sourceApps(_ item: LearnedItem, appNames: [Int64: String], limit: Int = 3) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in item.sourceDictationIDs.reversed() {
            guard let name = appNames[id], !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == limit { break }
        }
        return result
    }

    /// Only these formatting habits have a cleanup prompt hook. Filler observations remain
    /// visible as notes; offering Use for them would promise behavior we do not implement.
    static func canUseHabit(_ item: LearnedItem) -> Bool {
        item.kind == .styleSignal && ["format:lowercased", "format:droppedTerminalPeriod",
            "format:noGreeting", "format:noExclamation", "format:signOff:,"].contains(item.key)
    }

    /// A style signal as a sentence ("In Slack you usually write in lowercase"). The raw key
    /// (`format:lowercased`) is never shown. Unknown signals return nil and aren't listed.
    static func styleSentence(_ item: LearnedItem, appName: String) -> String? {
        guard item.kind == .styleSignal else { return nil }
        let key = item.key
        if key == "format:\(FormattingSignal.lowercased.rawValue)" {
            return "In \(appName) you usually write in lowercase"
        }
        if key == "format:\(FormattingSignal.droppedTerminalPeriod.rawValue)" {
            return "In \(appName) you leave off the final period"
        }
        if key == "format:noGreeting" { return "In \(appName) you leave out greetings" }
        if key == "format:noExclamation" { return "In \(appName) you leave out exclamation marks" }
        if let mark = suffix(of: key, after: "format:signOff:") {
            return "In \(appName) you end sign-offs with “\(mark)”"
        }
        if let word = suffix(of: key, after: "keep:") { return "In \(appName) you keep “\(word)”" }
        if let word = suffix(of: key, after: "drop:") { return "In \(appName) you delete “\(word)”" }
        return nil
    }

    /// The name a row uses for the item: the term itself, or "this habit" for style signals.
    static func displayName(_ item: LearnedItem) -> String {
        item.kind == .term ? item.value : "this habit"
    }

    private static func suffix(of key: String, after prefix: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let word = String(key.dropFirst(prefix.count))
        return word.isEmpty ? nil : word
    }

    // MARK: Exclusions

    /// An app the user can exclude from learning.
    struct AppChoice: Equatable, Identifiable, Sendable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apps the user recently dictated into, newest first, minus Hushy itself and apps already
    /// excluded: the shortlist for "Don't learn in these apps".
    static func exclusionCandidates(
        dictations: [Dictation], excluded: Set<String>, ownBundleIDs: Set<String> = Insights.ownBundleIDs, limit: Int = 10
    ) -> [AppChoice] {
        var seen: Set<String> = []
        var result: [AppChoice] = []
        for dictation in dictations {
            guard let bundleID = dictation.appBundleID, !bundleID.isEmpty,
                  !excluded.contains(bundleID), !ownBundleIDs.contains(bundleID),
                  seen.insert(bundleID).inserted
            else { continue }
            result.append(AppChoice(bundleID: bundleID, name: dictation.appName ?? bundleID))
            if result.count == limit { break }
        }
        return result
    }
}
