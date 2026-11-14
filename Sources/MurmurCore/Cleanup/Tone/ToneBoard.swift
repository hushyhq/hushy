import Foundation

/// One column of the tone page: a way of writing, holding the apps and websites that are written that way.
///
/// As spoken is a lane too (founder, 2026-10-28): an app or site in it is dictated word for word. Its card also
/// holds the switch that turns As spoken on for every app at once (`ToneSettings.isAsSpoken`), which wins over
/// every lane.
public enum ToneLane: String, CaseIterable, Identifiable, Sendable {
    case refined, professional, casual, prompt, asSpoken

    public var id: String { rawValue }

    public init(tone: DictationTone) {
        switch tone {
        case .refined: self = .refined
        case .professional: self = .professional
        case .casual: self = .casual
        }
    }

    /// The tone the lane stands for; `nil` for Prompt, which is a register, and As spoken, which skips cleanup.
    public var tone: DictationTone? {
        switch self {
        case .refined: .refined
        case .professional: .professional
        case .casual: .casual
        case .prompt, .asSpoken: nil
        }
    }

    public var title: String {
        switch self {
        case .prompt: ToneCopy.promptName
        case .asSpoken: ToneCopy.asSpokenTitle
        default: tone?.title ?? ""
        }
    }

    /// What is stored for an app or site placed here by hand.
    public var writing: AppWriting {
        switch self {
        case .prompt: .prompt
        case .asSpoken: .asSpoken
        default: tone.map(AppWriting.tone) ?? .prompt
        }
    }
}

/// One chip on the board: an app, a website, or a kind of app (what every app and website of that kind gets when
/// it has no choice of its own). Where it is written now, and where it would be with no choice of its own.
public struct ToneBoardApp: Identifiable, Equatable, Sendable {
    public enum Subject: Equatable, Sendable {
        case app
        /// A known site's key, or the host the person typed.
        case site(String)
        /// The tone for a kind of app (`ToneSettings.overrides`): it takes a tone, never Prompt or As spoken.
        case kind(StyleContext)
    }

    /// For a website or a kind, a row whose one identifier is `ToneBoard.siteChipID` or `ToneBoard.kindChipID`.
    public let row: AppToneRow
    /// The lane it is in: worked out with the same `ToneSettings.plan` and `register` calls the dictation uses.
    public let lane: ToneLane
    /// The lane it would be in if its own choice were cleared (its kind of app decides).
    public let naturalLane: ToneLane
    public let kind: ToneKind
    public var subject = Subject.app

    public var id: String { row.id }
    /// The website's key (`KnownWebsite.key`, or the host the person typed); nil for an app or a kind.
    public var siteKey: String? { if case .site(let key) = subject { key } else { nil } }
    public var isSite: Bool { siteKey != nil }
    public var kindPlace: StyleContext? { if case .kind(let place) = subject { place } else { nil } }
    public var isKind: Bool { kindPlace != nil }
    public var name: String { row.name }
    /// True when the person put it here; false when it follows its kind of app.
    public var isPlaced: Bool { lane != naturalLane }
}

/// One lane with its apps.
public struct ToneBoardLane: Identifiable, Equatable, Sendable {
    public let lane: ToneLane
    public let apps: [ToneBoardApp]
    /// The lane of the default tone (As spoken, while it is on for every app): apps and websites with nothing else to
    /// go by are written this way.
    public let isDefault: Bool
    /// False only for Prompt on a Mac whose writing model does not take a register: it is shown as coming, holds no
    /// apps and takes no drops.
    public let isAvailable: Bool

    public var id: ToneLane { lane }
}

/// The tone page, organised by tone: each lane holds the apps and websites written that way, and moving one between
/// lanes is a change to the same `appChoices` or `siteChoices` the dictation reads. Nothing here is stored; it is a
/// view of `ToneSettings`.
public struct ToneBoard: Equatable, Sendable {
    public let lanes: [ToneBoardLane]
    /// Code editors and terminals: no tone is ever applied there, so they cannot be moved.
    public let noTone: [AppToneRow]

    public func lane(_ lane: ToneLane) -> ToneBoardLane? { lanes.first { $0.lane == lane } }

    public func app(id: String) -> ToneBoardApp? {
        lanes.lazy.flatMap(\.apps).first { $0.id == id || $0.row.bundleIDs.contains(id) }
    }

    /// The lanes a chip can be moved to from where it is now. A kind takes only the lanes that are tones.
    public func destinations(for app: ToneBoardApp) -> [ToneLane] {
        lanes.filter { $0.isAvailable && $0.lane != app.lane && (!app.isKind || $0.lane.tone != nil) }.map(\.lane)
    }

    /// - Parameter promptAvailable: whether the writing model in use takes a register line
    ///   (`LocalModelEntry.understandsRegisterLines`). Without it the Prompt lane is shown as coming, and an AI app
    ///   sits in the lane of the tone it really gets.
    public static func make(
        settings: ToneSettings, installed: any InstalledApps, usage: [String: Int] = [:], promptAvailable: Bool
    ) -> ToneBoard {
        let candidates = ToneKinds.candidates(settings: settings, installed: installed, usage: usage)
        // Most dictated first, then the known table's order, then by name (the order `ToneKinds` uses inside a kind).
        let ordered = candidates.sorted(by: ToneKinds.ordered)
        let noTone = ordered.filter { !$0.row.usesTone || $0.kind == .code }.map(\.row)
        let sorted = ordered.filter { $0.row.usesTone && $0.kind != .code }.map {
            boardApp($0.row, kind: $0.kind, settings: settings, promptAvailable: promptAvailable)
        } + sites(in: settings).map { siteApp($0, settings: settings, promptAvailable: promptAvailable) }
            + StyleContext.allCases.map { kindApp($0, settings: settings) }
        let lanes = ToneLane.allCases.map { lane in
            ToneBoardLane(
                lane: lane, apps: sorted.filter { $0.lane == lane },
                isDefault: lane == .asSpoken ? settings.isAsSpoken : !settings.isAsSpoken && lane.tone == settings.defaultTone,
                isAvailable: lane != .prompt || promptAvailable)
        }
        return ToneBoard(lanes: lanes, noTone: noTone)
    }

    /// The lane one app is written in, from the dictation's own calls: its own As spoken first, then `register`
    /// (Prompt, when the model takes it), then the tone `plan` applies. As spoken for every app is left out, so the
    /// lanes still show where each app goes back to.
    public static func lane(
        for bundleID: String, kind: ToneKind, settings: ToneSettings, promptAvailable: Bool
    ) -> ToneLane {
        lane(for: bundleID, site: nil, category: kind.category, settings: settings, promptAvailable: promptAvailable)
    }

    static func lane(
        for bundleID: String, site: String?, category: AppCategory, settings: ToneSettings, promptAvailable: Bool
    ) -> ToneLane {
        var settings = settings
        settings.isAsSpoken = false
        if settings.dictationLevel(for: bundleID, site: site) == .verbatim { return .asSpoken }
        if promptAvailable, settings.register(for: category, bundleID: bundleID, site: site) == .prompt { return .prompt }
        return ToneLane(tone: settings.plan(for: category, bundleID: bundleID, site: site).tone ?? settings.defaultTone)
    }

    /// Moves one app or website to a lane. When the lane is where it would be anyway, its own choice is cleared, so
    /// it follows its kind again; otherwise the lane's way of writing is stored (for every identifier of an app).
    /// A lane that is not available, or an app that takes no tone, changes nothing.
    public static func moving(
        _ app: ToneBoardApp, to lane: ToneLane, in settings: ToneSettings, promptAvailable: Bool
    ) -> ToneSettings {
        guard app.row.usesTone, lane != .prompt || promptAvailable else { return settings }
        if let place = app.kindPlace {
            guard let tone = lane.tone else { return settings }
            return lane == app.naturalLane ? settings.resettingTone(for: place) : settings.settingTone(tone, for: place)
        }
        let writing: AppWriting? = lane == app.naturalLane ? nil : lane.writing
        if let key = app.siteKey { return settings.settingSite(writing, key: key) }
        return settings.settingApp(writing, bundleIDs: app.row.bundleIDs)
    }

    /// Adds an app the person picked to a lane: it is listed under its kind (`ToneSettings.addingApp`), then moved.
    /// Returns nil for an app that cannot take a tone (a browser, or a code editor or terminal).
    public static func adding(
        _ info: InstalledAppInfo, to lane: ToneLane, in settings: ToneSettings, promptAvailable: Bool
    ) -> ToneSettings? {
        let id = info.bundleID
        if AppCategory.isBrowser(id) || AppCategory.classify(bundleID: id) == .code { return nil }
        let declared = DeclaredAppCategory.kind(for: info)
        if declared == .code { return nil }
        let kind = settings.appKinds[id] ?? (AppCategory.classify(bundleID: id) != .other ? ToneKind.kind(forBundleID: id) : nil)
            ?? declared ?? .everythingElse
        let added = settings.addingApp(id, to: kind)
        let row = AppToneRow.customRow(bundleID: id, name: info.name, kind: kind, in: added)
        let app = boardApp(row, kind: kind, settings: added, promptAvailable: promptAvailable)
        return moving(app, to: lane, in: added, promptAvailable: promptAvailable)
    }

    // MARK: Websites

    /// What a website chip is identified by on the board (and while dragged). Never a bundle identifier.
    public static func siteChipID(_ key: String) -> String { sitePrefix + key }
    static let sitePrefix = "site:"
    /// Any browser: the dictation's calls honour a site's choice only in one, so the board asks as one would.
    static let anyBrowser = "com.apple.Safari"

    /// Lists a website on the page and moves it to a lane (no choice of its own when that is its kind's lane).
    public static func addingSite(
        _ key: String, to lane: ToneLane, in settings: ToneSettings, promptAvailable: Bool
    ) -> ToneSettings {
        let added = settings.addingSite(key)
        return moving(siteApp(key, settings: added, promptAvailable: promptAvailable), to: lane, in: added,
                      promptAvailable: promptAvailable)
    }

    /// The same for an address the person typed: kept as a known site's key or as its bare host. Returns nil for
    /// anything that is not a web address.
    public static func addingSite(
        address: String, to lane: ToneLane, in settings: ToneSettings, promptAvailable: Bool
    ) -> ToneSettings? {
        guard let key = WebsiteAddress.key(from: address) else { return nil }
        return addingSite(key, to: lane, in: settings, promptAvailable: promptAvailable)
    }

    public static func removingSite(_ app: ToneBoardApp, from settings: ToneSettings) -> ToneSettings {
        app.siteKey.map(settings.removingSite) ?? settings
    }

    /// The known sites still to offer in "Add website" (those not on the page yet), in the table's order.
    public static func sitesToOffer(_ settings: ToneSettings) -> [KnownWebsite] {
        let shown = Set(sites(in: settings))
        return KnownWebsites.all.filter { !shown.contains($0.key) }
    }

    /// The websites on the page: known ones in the table's order, then the hosts the person typed, by name.
    static func sites(in settings: ToneSettings) -> [String] {
        let keys = settings.addedSites.union(settings.siteChoices.keys)
        let known = KnownWebsites.all.map(\.key).filter(keys.contains)
        return known + keys.subtracting(known).sorted()
    }

    private static func siteApp(_ key: String, settings: ToneSettings, promptAvailable: Bool) -> ToneBoardApp {
        let site = KnownWebsites.site(key: key)
        let category = site?.category ?? .other
        let kind = ToneKind.kind(for: category)
        let row = AppToneRow(
            bundleIDs: [siteChipID(key)], name: WebsiteAddress.name(forKey: key), isAI: category == .aiPrompts,
            selected: .useDefault, defaultTone: settings.defaultTone, defaultFrom: nil, usesTone: true, options: [])
        let now = lane(for: anyBrowser, site: key, category: category, settings: settings, promptAvailable: promptAvailable)
        let natural = lane(for: anyBrowser, site: key, category: category, settings: settings.settingSite(nil, key: key),
                           promptAvailable: promptAvailable)
        return ToneBoardApp(row: row, lane: now, naturalLane: natural, kind: kind, subject: .site(key))
    }

    // MARK: Kinds of app

    /// What a kind's chip is identified by on the board (and while dragged).
    public static func kindChipID(_ place: StyleContext) -> String { kindPrefix + place.rawValue }
    static let kindPrefix = "kind:"

    /// A kind sits in the lane of its tone; with no tone chosen it is where it starts (Professional for Email, the
    /// default tone elsewhere).
    private static func kindApp(_ place: StyleContext, settings: ToneSettings) -> ToneBoardApp {
        let row = AppToneRow(
            bundleIDs: [kindChipID(place)], name: ToneCopy.kindChipName(place), isAI: false, selected: .useDefault,
            defaultTone: settings.defaultTone, defaultFrom: nil, usesTone: true, options: [])
        let natural = ToneSettings.shippedPlaceTones[place] ?? settings.defaultTone
        return ToneBoardApp(
            row: row, lane: ToneLane(tone: settings.tone(for: place)), naturalLane: ToneLane(tone: natural),
            kind: ToneKind.allCases.first { $0.hasOwnTone && $0.place == place } ?? .everythingElse, subject: .kind(place))
    }

    private static func boardApp(
        _ row: AppToneRow, kind: ToneKind, settings: ToneSettings, promptAvailable: Bool
    ) -> ToneBoardApp {
        let now = lane(for: row.id, kind: kind, settings: settings, promptAvailable: promptAvailable)
        let natural = lane(
            for: row.id, kind: kind, settings: settings.settingApp(nil, bundleIDs: row.bundleIDs),
            promptAvailable: promptAvailable)
        return ToneBoardApp(row: row, lane: now, naturalLane: natural, kind: kind)
    }
}

extension ToneKind {
    /// The kind dictation classified as `category` is shown under.
    static func kind(for category: AppCategory) -> ToneKind {
        switch category {
        case .code: .code
        case .aiPrompts: .aiTools
        case .workMessages: .workMessages
        case .email: .email
        case .personalMessages: .personalMessages
        case .documents, .other: .everythingElse
        }
    }

    /// The kind of app dictation in it is classified as. Used to ask `ToneSettings` what an app gets; a placement the
    /// person corrected (`appKinds`) is applied by `ToneSettings` itself, so the answer is the dictation's.
    public var category: AppCategory {
        switch self {
        case .workMessages: .workMessages
        case .email: .email
        case .personalMessages: .personalMessages
        case .aiTools: .aiPrompts
        case .everythingElse: .other
        case .code: .code
        }
    }
}
