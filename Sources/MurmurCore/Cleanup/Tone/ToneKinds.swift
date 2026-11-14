import Foundation

/// The kinds of apps the tone screens group the person's apps into. A kind is a way of showing the
/// settings that already exist: a kind with its own tone is one of the places (`StyleContext`).
/// A person's correction to an app's placement is stored in `ToneSettings`. AI tools use the
/// Everything else tone until Prompt exists, and code editors take no tone.
public enum ToneKind: String, CaseIterable, Identifiable, Sendable {
    case workMessages, email, personalMessages, aiTools, everythingElse, code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workMessages: StyleContext.workMessages.title
        case .email: StyleContext.email.title
        case .personalMessages: StyleContext.personalMessages.title
        case .aiTools: "AI tools"
        case .everythingElse: StyleContext.other.title
        case .code: "Code editors & terminals"
        }
    }

    public var symbol: String {
        switch self {
        case .workMessages: StyleContext.workMessages.symbol
        case .email: StyleContext.email.symbol
        case .personalMessages: StyleContext.personalMessages.symbol
        case .aiTools: "sparkles"
        case .everythingElse: StyleContext.other.symbol
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The place whose tone apps of this kind get. AI tools follow Everything else; code has none.
    public var place: StyleContext? {
        switch self {
        case .workMessages: .workMessages
        case .email: .email
        case .personalMessages: .personalMessages
        case .aiTools, .everythingElse: .other
        case .code: nil
        }
    }

    /// Whether the kind has a tone of its own to choose.
    public var hasOwnTone: Bool { self != .aiTools && self != .code }

    /// The kind an app belongs to, by how dictation in it is classified. Browsers are not apps here.
    public static func kind(forBundleID id: String) -> ToneKind {
        KnownWritingApps.app(forBundleID: id)?.toneKind ?? kind(for: AppCategory.classify(bundleID: id))
    }
}

/// One kind, with the apps on this Mac that belong to it and the one tone for the whole kind.
public struct ToneKindGroup: Identifiable, Equatable, Sendable {
    public let kind: ToneKind
    /// What is chosen for the kind: "Default", or a tone. Always `.useDefault` for kinds with no tone of their own.
    public let selected: AppToneOption.Value
    /// The tone the kind gets (nil for code).
    public let tone: DictationTone?
    /// What "Default" means here: Professional for Email, the overall default elsewhere.
    public let defaultTone: DictationTone?
    /// The menu for the kind; empty for AI tools and code.
    public let options: [AppToneOption]
    /// The apps shown, in order. When a limit applies, the rest are counted in `hiddenCount`.
    public let apps: [AppToneRow]
    public let hiddenCount: Int
    /// A short line under the title: where the tone comes from, or why there is none.
    public let note: String?

    public var id: ToneKind { kind }
    public var isEmpty: Bool { apps.isEmpty }
    /// A "Prompt · Coming" marker belongs to AI tools; it is shown, never selectable.
    public var showsPromptComing: Bool { kind == .aiTools }
}

public enum ToneKinds {
    /// How many apps one kind shows before "and N more" in a compact list.
    public static let compactLimit = 4

    /// Every kind, with the apps on this Mac that belong to it.
    ///
    /// Which apps: the known table first (found by identifier), then every other installed app that declares
    /// something that places it (`DeclaredAppCategory`), then apps the person added by hand and apps they have
    /// dictated into that cannot be placed (these go where dictation in them is classified, Everything else
    /// unless it is a known code tool). An app that is no longer installed is not shown; the tone saved for it
    /// stays in the setting and comes back with the app.
    ///
    /// Order inside a kind: the apps the person dictates into most, most first (`usage` is words per bundle
    /// identifier, kept locally); then the table's own order; then by name. On a new install that is a fixed,
    /// sensible order.
    ///
    /// `includeEmpty` is for Settings: the four kinds that have a tone of their own stay even with no apps
    /// (the tone also applies to websites), and AI tools and code editors show only when there is one.
    /// Onboarding drops every empty kind. `limit` caps the apps shown per kind.
    public static func groups(
        settings: ToneSettings, installed: any InstalledApps, usage: [String: Int] = [:],
        includeEmpty: Bool, limit: Int? = nil
    ) -> [ToneKindGroup] {
        let candidates = candidates(settings: settings, installed: installed, usage: usage)
        return ToneKind.allCases.compactMap { kind in
            let rows = candidates.filter { $0.kind == kind }.sorted(by: ordered).map(\.row)
            guard !rows.isEmpty || (includeEmpty && kind.hasOwnTone) else { return nil }
            let shown = limit.map { Array(rows.prefix($0)) } ?? rows
            return group(kind, rows: shown, hidden: rows.count - shown.count, settings: settings)
        }
    }

    /// One app the tone screens can show, with the kind it is shown under. Shared with `ToneBoard`.
    struct Candidate {
        let kind: ToneKind
        let row: AppToneRow
        let words: Int
        /// Position in the known table, or nil for an app that is not in it.
        let tableIndex: Int?
    }

    static func ordered(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.words != rhs.words { return lhs.words > rhs.words }
        switch (lhs.tableIndex, rhs.tableIndex) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.row.name.localizedCaseInsensitiveCompare(rhs.row.name) == .orderedAscending
        }
    }

    static func candidates(settings: ToneSettings, installed: any InstalledApps, usage: [String: Int]) -> [Candidate] {
        var result: [Candidate] = []
        var taken = Set<String>()
        for (index, app) in KnownWritingApps.all.enumerated() where app.bundleIDs.contains(where: installed.isInstalled) {
            taken.formUnion(app.bundleIDs)
            result.append(Candidate(kind: app.bundleIDs.compactMap { settings.appKinds[$0] }.first ?? app.toneKind,
                                    row: AppToneRow.row(for: app, in: settings),
                                    words: app.bundleIDs.reduce(0) { $0 + (usage[$1] ?? 0) }, tableIndex: index))
        }
        let knownIDs = Set(KnownWritingApps.all.flatMap(\.bundleIDs))
        func isOffered(_ id: String) -> Bool { !knownIDs.contains(id) && !AppCategory.isBrowser(id) && !Insights.ownBundleIDs.contains(id) }

        for app in installed.discoveredApps() where isOffered(app.bundleID) && taken.insert(app.bundleID).inserted {
            let words = usage[app.bundleID] ?? 0
            let used = words > 0 || settings.appChoices[app.bundleID] != nil
                || settings.addedApps.contains(app.bundleID) || settings.appKinds[app.bundleID] != nil
            // How dictation in it is already classified wins, so the screen never says otherwise. Else what the app
            // declares places it; an app that cannot be placed is shown only once the person has used or added it.
            let known = AppCategory.classify(bundleID: app.bundleID) != .other
            guard let discoveredKind = known ? ToneKind.kind(forBundleID: app.bundleID)
                : (DeclaredAppCategory.kind(for: app) ?? (used ? .everythingElse : nil)) else { continue }
            let kind = settings.appKinds[app.bundleID] ?? discoveredKind
            result.append(Candidate(kind: kind, row: AppToneRow.customRow(bundleID: app.bundleID, name: app.name, kind: kind, in: settings),
                                    words: words, tableIndex: nil))
        }
        // Apps added by hand or dictated into that the discovery did not list (installed outside the usual folders).
        let wanted = Set(settings.appChoices.keys).union(settings.addedApps).union(settings.appKinds.keys)
            .union(usage.filter { $0.value > 0 }.keys)
        for id in wanted.sorted() where isOffered(id) && !taken.contains(id) && installed.isInstalled(id) {
            let kind = settings.kind(for: id)
            result.append(Candidate(kind: kind, row: AppToneRow.customRow(bundleID: id, name: installed.displayName(id) ?? id, kind: kind, in: settings),
                                    words: usage[id] ?? 0, tableIndex: nil))
        }
        return result
    }

    private static func group(_ kind: ToneKind, rows: [AppToneRow], hidden: Int, settings: ToneSettings) -> ToneKindGroup {
        guard let place = kind.place else {
            return ToneKindGroup(kind: kind, selected: .useDefault, tone: nil, defaultTone: nil, options: [], apps: rows,
                                 hiddenCount: hidden, note: ToneCopy.codeKindNote)
        }
        guard kind.hasOwnTone else {
            return ToneKindGroup(kind: kind, selected: .useDefault, tone: settings.tone(for: place), defaultTone: nil,
                                 options: [], apps: rows, hiddenCount: hidden, note: ToneCopy.aiToolsNote(settings))
        }
        let startsOn = ToneSettings.shippedPlaceTones[place] ?? settings.defaultTone
        let chosen = settings.hasOverride(for: place) && !settings.isShippedTone(for: place)
        let options = [AppToneOption(value: .useDefault, title: "Default (\(startsOn.title))", badge: nil, isSelectable: true)]
            + DictationTone.allCases.map { AppToneOption(value: .tone($0), title: $0.title, badge: nil, isSelectable: true) }
        // The menu already says what the kind uses; a line is added only for what it does not say: an earlier
        // layout still in use, or Email starting on Professional.
        let informative = settings.keptLayout(for: place) != nil || (settings.isShippedTone(for: place) && !chosen)
        return ToneKindGroup(
            kind: kind, selected: chosen ? .tone(settings.tone(for: place)) : .useDefault, tone: settings.tone(for: place),
            defaultTone: startsOn, options: options, apps: rows, hiddenCount: hidden,
            note: informative ? ToneCopy.destinationNote(settings, for: place) : nil)
    }

    /// Applies a pick for a whole kind. "Default" goes back to where the kind starts; a kind with no tone
    /// of its own, or a choice that cannot be picked, changes nothing.
    public static func applying(_ value: AppToneOption.Value, to kind: ToneKind, in settings: ToneSettings) -> ToneSettings {
        guard kind.hasOwnTone, let place = kind.place else { return settings }
        switch value {
        case .useDefault: return settings.resettingTone(for: place)
        case .tone(let tone): return settings.settingTone(tone, for: place)
        case .prompt: return settings
        }
    }
}
