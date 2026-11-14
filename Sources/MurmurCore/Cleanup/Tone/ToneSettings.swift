import Foundation

/// What the person picks as the default way their dictation should read. "As spoken" is the one
/// way to skip the cleanup pass; the three tones all go through it.
public enum ToneChoice: String, CaseIterable, Sendable, Identifiable {
    case refined, casual, professional, asSpoken

    public var id: String { rawValue }

    public init(tone: DictationTone) {
        self = ToneChoice(rawValue: tone.rawValue) ?? .refined
    }

    /// `nil` for "As spoken".
    public var tone: DictationTone? { DictationTone(rawValue: rawValue) }

    public var title: String { tone?.title ?? "As spoken" }

    public var detail: String { tone?.detail ?? "Word for word, including um and uh. Voice commands still work." }
}

/// What a dictation needs from the tone setting for one target app: the cleanup level, the tone
/// to apply afterwards and the layout to lay it out with.
public struct TonePlan: Equatable, Sendable {
    public let level: CleanupLevel
    /// `nil` when nothing is applied: "As spoken", or a code editor or terminal (which are repaired for grammar but
    /// given no tone register and no layout).
    public let tone: DictationTone?
    public let context: StyleContext?
    public let layout: WritingStyle?

    /// The pair the pipeline lays text out with, or `nil` when the target is never styled.
    public var style: (context: StyleContext, style: WritingStyle)? {
        guard let context, let layout else { return nil }
        return (context, layout)
    }

    /// The level this dictation runs at: the mode's own. The stock Default mode already follows the person's setting
    /// (`Mode.resolvingAppCleanupLevel`), which is the same for a code editor or terminal as for any other app: it is
    /// repaired for grammar too, with the code in it kept as dictated (`CleanupOptions.isCodeContext`).
    public func level(for mode: Mode) -> CleanupLevel { mode.cleanupLevel }
}

/// What a single app or website is set to write in: a tone, `.prompt` (the way of writing for AI apps, raw value
/// "prompt"), or `.asSpoken` (word for word, raw value "asSpoken").
/// A model that takes register lines writes a `.prompt` app as a prompt (`ToneSettings.register`); for the tone
/// pass and the layout it is no tone of its own, so the app follows its kind of app (`ToneSettings.appTone`).
/// The tone page offers Prompt only while the model in use takes register lines (`ToneBoard`).
/// An `.asSpoken` app skips cleanup the way the every-app switch does, for that app alone
/// (`ToneSettings.dictationLevel(for:site:)`, founder 2026-10-28).
public enum AppWriting: Equatable, Sendable {
    case tone(DictationTone)
    case prompt
    case asSpoken

    public static let promptRawValue = "prompt"
    public static let asSpokenRawValue = "asSpoken"

    public var rawValue: String {
        switch self {
        case .tone(let tone): tone.rawValue
        case .prompt: Self.promptRawValue
        case .asSpoken: Self.asSpokenRawValue
        }
    }

    /// An unknown value (written by a later version) is `nil`, and is dropped when read.
    public init?(rawValue: String) {
        if rawValue == Self.promptRawValue { self = .prompt; return }
        if rawValue == Self.asSpokenRawValue { self = .asSpoken; return }
        guard let tone = DictationTone(rawValue: rawValue) else { return nil }
        self = .tone(tone)
    }

    /// Whether the older per-kind screens offer it. They never offer Prompt; the tone page does, by model.
    public var isAvailable: Bool { if case .tone = self { true } else { false } }
}

/// The tone setting: one default tone, an optional different tone for each kind of place people
/// write (`StyleContext`), a choice per app and per website, and "As spoken" for every app as one switch on top.
///
/// `keptLayouts` holds a layout someone picked under the old Style page that has no tone of its
/// own ("very casual" and "Excited!"). It keeps that destination exactly as it was until a tone
/// is picked for it.
///
/// Order of precedence, most specific first: As spoken for every app (`isAsSpoken`); then the app's own choice
/// (`appChoices`, keyed by bundle identifier), or in a browser the placed website's (`siteChoices`, keyed by a known
/// site's key or the host the person typed); then the kind of app (`overrides`); then the default tone. All of it
/// is stored only here, on this Mac.
public struct ToneSettings: Equatable, Sendable {
    public var isAsSpoken: Bool
    public var defaultTone: DictationTone
    public private(set) var overrides: [StyleContext: DictationTone]
    public private(set) var keptLayouts: [StyleContext: WritingStyle]
    public private(set) var appChoices: [String: AppWriting]
    /// Explicit corrections and hand-added apps live beside per-app tones in the same setting.
    public private(set) var appKinds: [String: ToneKind]
    public private(set) var addedApps: Set<String>
    /// Websites placed on a tone: a known site's key ("google-docs") or a host the person typed. Never a URL.
    public private(set) var siteChoices: [String: AppWriting]
    /// Websites listed on the tone page, including those that follow their kind with no choice of their own.
    public private(set) var addedSites: Set<String>

    /// Where a new install starts: Refined, and Professional for email.
    public static let standard = ToneSettings(overrides: shippedPlaceTones)

    /// The tone a kind of app starts on when the person has not chosen one.
    public static let shippedPlaceTones: [StyleContext: DictationTone] = [.email: .professional]

    public init(
        isAsSpoken: Bool = false, defaultTone: DictationTone = .refined,
        overrides: [StyleContext: DictationTone] = [:], keptLayouts: [StyleContext: WritingStyle] = [:],
        appChoices: [String: AppWriting] = [:], appKinds: [String: ToneKind] = [:], addedApps: Set<String> = [],
        siteChoices: [String: AppWriting] = [:], addedSites: Set<String> = []
    ) {
        self.isAsSpoken = isAsSpoken
        self.defaultTone = defaultTone
        self.overrides = overrides
        self.keptLayouts = keptLayouts
        self.appChoices = appChoices
        self.appKinds = appKinds
        self.addedApps = addedApps
        self.siteChoices = siteChoices
        self.addedSites = addedSites
    }

    /// True while a kind of app is on the tone it shipped with.
    public func isShippedTone(for context: StyleContext) -> Bool {
        overrides[context] != nil && overrides[context] == Self.shippedPlaceTones[context]
    }

    // MARK: Per app

    /// The tone chosen for this exact app, if any. A "prompt" choice is not a tone, so it counts as none.
    public func appTone(for bundleID: String?) -> DictationTone? {
        guard let bundleID, case .tone(let tone)? = appChoices[bundleID] else { return nil }
        return tone
    }

    /// Sets (or with `nil` clears) the choice for every identifier of one app.
    public func settingApp(_ writing: AppWriting?, bundleIDs: [String]) -> ToneSettings {
        var copy = self
        for id in bundleIDs { copy.appChoices[id] = writing }
        return copy
    }

    // MARK: Per website

    /// Sets (or with `nil` clears) the choice for one website. Its key is kept listed on the page.
    public func settingSite(_ writing: AppWriting?, key: String) -> ToneSettings {
        var copy = self
        copy.siteChoices[key] = writing
        return copy
    }

    public func addingSite(_ key: String) -> ToneSettings {
        var copy = self
        copy.addedSites.insert(key)
        return copy
    }

    /// Forgets a website: its choice and its place on the page.
    public func removingSite(_ key: String) -> ToneSettings {
        var copy = self
        copy.siteChoices[key] = nil
        copy.addedSites.remove(key)
        return copy
    }

    /// What key-down needs to tell which placed site a tab is; `nil` while no site has a choice, so nothing is read.
    public var siteMatcher: WebsiteMatcher? { WebsiteMatcher(placed: siteChoices.keys) }

    /// The choice that applies to one target: in a browser the placed site's (a tab can be anything, so the browser
    /// itself never carries one), elsewhere the app's own.
    public func writing(bundleID: String?, site: String?) -> AppWriting? {
        if AppCategory.isBrowser(bundleID) { return site.flatMap { siteChoices[$0] } }
        return bundleID.flatMap { appChoices[$0] }
    }

    public func kind(for bundleID: String) -> ToneKind { appKinds[bundleID] ?? ToneKind.kind(forBundleID: bundleID) }

    public func movingApp(to kind: ToneKind?, bundleIDs: [String]) -> ToneSettings {
        var copy = self
        for id in bundleIDs { copy.appKinds[id] = kind }
        return copy
    }

    public func addingApp(_ bundleID: String, to kind: ToneKind) -> ToneSettings {
        var copy = movingApp(to: kind, bundleIDs: [bundleID])
        copy.addedApps.insert(bundleID)
        return copy
    }

    public func tone(for context: StyleContext) -> DictationTone { overrides[context] ?? defaultTone }

    /// Goes back to where this kind of app starts: Professional for Email, the default tone elsewhere.
    public func resettingTone(for context: StyleContext) -> ToneSettings {
        var copy = self
        copy.overrides[context] = Self.shippedPlaceTones[context]
        copy.keptLayouts[context] = nil
        return copy
    }

    public func hasOverride(for context: StyleContext) -> Bool { overrides[context] != nil }

    /// The earlier layout still in force for this destination, if any.
    public func keptLayout(for context: StyleContext) -> WritingStyle? { keptLayouts[context] }

    public func layout(for context: StyleContext) -> WritingStyle {
        keptLayouts[context] ?? tone(for: context).formattingStyle
    }

    /// The default shown in the picker.
    public var choice: ToneChoice {
        get { isAsSpoken ? .asSpoken : ToneChoice(tone: defaultTone) }
        set {
            if let tone = newValue.tone { defaultTone = tone }
            isAsSpoken = newValue == .asSpoken
        }
    }

    /// Picking a tone for a destination replaces any layout kept from before. `nil` goes back to
    /// the default tone.
    public func settingTone(_ tone: DictationTone?, for context: StyleContext) -> ToneSettings {
        var copy = self
        copy.overrides[context] = tone
        copy.keptLayouts[context] = nil
        return copy
    }

    /// `bundleID` is the focused app, when known; `site` the placed website a browser tab was matched to. An app's
    /// own choice (or the site's, in a browser) wins over its kind of app: As spoken skips cleanup, a tone is applied.
    /// A browser never carries one itself (a tab can be anything). A code editor or terminal is given the same
    /// grammar repair as any other app (Polished) but never a tone or a layout: a contraction pass or a
    /// line layout would edit code, and `CleanupOptions.isCodeContext` keeps the code in what is said as dictated.
    /// No choice can be stored for a code app (the pickers refuse it), so there is none to honour here.
    public func plan(for category: AppCategory, bundleID: String? = nil, site: String? = nil) -> TonePlan {
        let own = writing(bundleID: bundleID, site: site)
        if isAsSpoken || own == .asSpoken { return TonePlan(level: .verbatim, tone: nil, context: nil, layout: nil) }
        // Code remains code regardless of a saved placement. Browser tabs keep their tab category.
        let movedContext = AppCategory.isBrowser(bundleID) ? nil : bundleID.flatMap { appKinds[$0]?.place }
        let context: StyleContext? = category == .code ? nil : (movedContext ?? StyleContext.from(category))
        guard let context else {
            return TonePlan(level: .polished, tone: nil, context: nil, layout: nil)
        }
        if case .tone(let tone)? = own {
            return TonePlan(level: .polished, tone: tone, context: context, layout: tone.formattingStyle)
        }
        return TonePlan(level: .polished, tone: tone(for: context), context: context, layout: layout(for: context))
    }

    /// The register a model that understands register lines is asked to write this dictation in, or `nil` for none.
    ///
    /// - "As spoken" (for every app, or this app's or site's own), Refined, and a code editor or terminal that is not an
    ///   agent session: none.
    /// - The app's own choice (in a browser, the placed site's) wins: its tone's register (Casual, Professional), none
    ///   for Refined, or Prompt.
    /// - Otherwise an AI app (`.aiPrompts`: Claude, ChatGPT, Codex and similar, and a terminal agent session), or an
    ///   app the person moved to AI tools, is written as a prompt, whatever the tone for its place is.
    /// - Otherwise the tone `plan(for:bundleID:)` picks.
    ///
    /// Only a model with `LocalModelEntry.understandsRegisterLines` is sent it; see `SmartCleaner.sendsRegisterLines`.
    public func register(for category: AppCategory, bundleID: String? = nil, site: String? = nil) -> IntentRegister? {
        if isAsSpoken || category == .code { return nil }
        switch writing(bundleID: bundleID, site: site) {
        case .asSpoken: return nil
        case .tone(let tone): return IntentRegister(tone: tone)
        case .prompt: return .prompt
        case nil: break
        }
        let moved = AppCategory.isBrowser(bundleID) ? nil : bundleID.flatMap { appKinds[$0] }
        if moved == .aiTools || (moved == nil && category == .aiPrompts) { return .prompt }
        return plan(for: category, bundleID: bundleID, site: site).tone.flatMap(IntentRegister.init(tone:))
    }

    /// A stable one-line summary, for noticing that something changed.
    public var fingerprint: String {
        let places = StyleContext.allCases.map { "\($0.rawValue):\(overrides[$0]?.rawValue ?? "-")/\(keptLayouts[$0]?.rawValue ?? "-")" }
        let apps = appChoices.keys.sorted().map { "\($0)=\(appChoices[$0]?.rawValue ?? "-")" }
        let kinds = appKinds.keys.sorted().map { "\($0)=\(appKinds[$0]?.rawValue ?? "-")" }
        let sites = siteChoices.keys.sorted().map { "\($0)=\(siteChoices[$0]?.rawValue ?? "-")" }
        return "\(isAsSpoken ? "asSpoken" : "tone")|\(defaultTone.rawValue)|" + places.joined(separator: ",") + "|" + apps.joined(separator: ",") + "|" + kinds.joined(separator: ",") + "|" + addedApps.sorted().joined(separator: ",")
            + "|" + sites.joined(separator: ",") + "|" + addedSites.sorted().joined(separator: ",")
    }

    /// The level for notes and imported files, which are never given a tone.
    public var noteCleanupLevel: CleanupLevel { isAsSpoken ? .verbatim : .clean }

    /// The level for a dictation before the target app is known, and for keeping the model warm: polished unless
    /// As spoken is on for every app.
    public var dictationLevel: CleanupLevel { isAsSpoken ? .verbatim : .polished }

    /// The level for a dictation into this app (or, in a browser, this placed site), decided at key-down: word for
    /// word when As spoken is on for every app or the app or site sits in As spoken. The stock Default mode takes it
    /// (`Mode.resolvingAppCleanupLevel`); a mode picked for one dictation keeps its own.
    public func dictationLevel(for bundleID: String?, site: String? = nil) -> CleanupLevel {
        isAsSpoken || writing(bundleID: bundleID, site: site) == .asSpoken ? .verbatim : .polished
    }
}

// MARK: Storage and migration

extension ToneSettings: Codable {
    private struct Stored: Codable {
        var isAsSpoken: Bool
        var defaultTone: String
        var overrides: [String: String]
        var keptLayouts: [String: String]
        /// Absent in data saved before per-app tones, which is why it is optional.
        var apps: [String: String]?
        var appKinds: [String: String]?
        var addedApps: [String]?
        /// Absent in data saved before websites could be placed.
        var sites: [String: String]?
        var addedSites: [String]?
    }

    public init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        self.init(
            isAsSpoken: stored.isAsSpoken,
            defaultTone: DictationTone(rawValue: stored.defaultTone) ?? .refined,
            overrides: stored.overrides.reduce(into: [:]) { result, pair in
                if let context = StyleContext(rawValue: pair.key), let tone = DictationTone(rawValue: pair.value) {
                    result[context] = tone
                }
            },
            keptLayouts: stored.keptLayouts.reduce(into: [:]) { result, pair in
                if let context = StyleContext(rawValue: pair.key), let style = WritingStyle(rawValue: pair.value) {
                    result[context] = style
                }
            },
            appChoices: (stored.apps ?? [:]).reduce(into: [:]) { result, pair in
                if let writing = AppWriting(rawValue: pair.value) { result[pair.key] = writing }
            }, appKinds: (stored.appKinds ?? [:]).reduce(into: [:]) { result, pair in
                if let kind = ToneKind(rawValue: pair.value), kind != .code { result[pair.key] = kind }
            }, addedApps: Set(stored.addedApps ?? []),
            siteChoices: (stored.sites ?? [:]).reduce(into: [:]) { result, pair in
                if let writing = AppWriting(rawValue: pair.value) { result[pair.key] = writing }
            }, addedSites: Set(stored.addedSites ?? []))
    }

    public func encode(to encoder: Encoder) throws {
        try Stored(
            isAsSpoken: isAsSpoken, defaultTone: defaultTone.rawValue,
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.rawValue) }),
            keptLayouts: Dictionary(uniqueKeysWithValues: keptLayouts.map { ($0.key.rawValue, $0.value.rawValue) }),
            apps: appChoices.isEmpty ? nil : appChoices.mapValues(\.rawValue),
            appKinds: appKinds.isEmpty ? nil : appKinds.mapValues(\.rawValue),
            addedApps: addedApps.isEmpty ? nil : addedApps.sorted(),
            sites: siteChoices.isEmpty ? nil : siteChoices.mapValues(\.rawValue),
            addedSites: addedSites.isEmpty ? nil : addedSites.sorted()
        ).encode(to: encoder)
    }
}

extension ToneSettings {
    /// What earlier versions stored: the cleanup level and one writing style per destination.
    public struct Earlier: Equatable, Sendable {
        public var cleanupLevel: String?
        public var styles: [String: String]
        /// Someone who has used Hushy before. A first launch starts from `ToneSettings.standard`.
        public var isExistingInstall: Bool

        public init(cleanupLevel: String?, styles: [String: String], isExistingInstall: Bool) {
            self.cleanupLevel = cleanupLevel
            self.styles = styles
            self.isExistingInstall = isExistingInstall
        }
    }

    /// Maps earlier settings to the nearest tone without changing what anyone sees today:
    ///
    /// - "As spoken" stays "As spoken"; "Cleaned up" and "Polished" become Refined.
    /// - For each destination, the style in force today (a stored choice, else the old default,
    ///   which was Casual for personal messages and Formal elsewhere) maps: Formal to Refined
    ///   (same layout); Casual to Casual (same layout, plus everyday contractions, accepted by the
    ///   founder 2026-10-06); "very casual" and "Excited!" to Refined with that layout kept,
    ///   because no tone writes them.
    /// - Email starts on Professional (founder, 2026-10-06) unless the person had chosen a style for
    ///   it: then their choice is kept, written down explicitly so the new start never replaces it.
    public static func migrated(from earlier: Earlier) -> ToneSettings {
        guard earlier.isExistingInstall else { return .standard }
        var settings = ToneSettings(isAsSpoken: earlier.cleanupLevel == CleanupLevel.verbatim.rawValue)
        for context in StyleContext.allCases {
            let stored = earlier.styles[context.rawValue].flatMap(WritingStyle.init(rawValue:))
            if stored == nil, let shipped = shippedPlaceTones[context] {
                settings = settings.settingTone(shipped, for: context)
                continue
            }
            let style = stored ?? context.defaultStyle
            let explicitRefined = shippedPlaceTones[context] != nil
            switch style {
            case .formal: if explicitRefined { settings = settings.settingTone(.refined, for: context) }
            case .casual: settings = settings.settingTone(.casual, for: context)
            case .veryCasual, .excited:
                if explicitRefined { settings = settings.settingTone(.refined, for: context) }
                settings.keptLayouts[context] = style
            }
        }
        return settings
    }
}
