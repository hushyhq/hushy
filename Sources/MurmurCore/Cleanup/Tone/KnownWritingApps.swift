import Foundation

/// A well-known app people write in, for the per-app tone list.
public struct KnownWritingApp: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Chat, mail and notes apps: tones apply.
        case writing
        /// An AI app: tones apply, and "Prompt" is coming.
        case ai
        /// An AI code editor: it is code, so no tone applies; "Prompt" is coming.
        case aiEditor
        /// A code editor or terminal: no tone applies.
        case code
    }

    /// Every identifier the app has shipped under (the first is the one used for the row).
    public let bundleIDs: [String]
    public let name: String
    public let kind: Kind

    public init(bundleIDs: [String], name: String, kind: Kind) {
        self.bundleIDs = bundleIDs
        self.name = name
        self.kind = kind
    }

    public var id: String { bundleIDs[0] }

    /// The kind of app (place) its dictation belongs to; `nil` for a code editor.
    public var context: StyleContext? {
        switch kind {
        case .aiEditor, .code: nil
        default: StyleContext.from(AppCategory.classify(bundleID: id))
        }
    }

    public var isAI: Bool { kind == .ai || kind == .aiEditor }

    /// The group the app is shown in. It follows how the app is classified when someone dictates in it.
    public var toneKind: ToneKind {
        switch kind {
        case .ai: .aiTools
        case .aiEditor, .code: .code
        case .writing:
            switch context {
            case .workMessages: .workMessages
            case .email: .email
            case .personalMessages: .personalMessages
            default: .everythingElse
            }
        }
    }
}

/// What the machine can say about an app. Asking whether a known app is installed is a Launch
/// Services lookup by identifier: no folder is scanned and no permission is needed.
public protocol InstalledApps: Sendable {
    func isInstalled(_ bundleID: String) -> Bool
    /// The name the app shows on this Mac, if it is installed.
    func displayName(_ bundleID: String) -> String?
    /// Every installed app that can be placed in a kind, with what it declares about itself. Read from the
    /// apps' own Info.plist files, once and cached by the caller; empty where nothing is looked up.
    func discoveredApps() -> [InstalledAppInfo]
}

extension InstalledApps {
    public func discoveredApps() -> [InstalledAppInfo] { [] }
}

public enum KnownWritingApps {
    /// Well-known apps, by kind. Only installed ones are ever shown (`ToneKinds`).
    public static let all: [KnownWritingApp] = [
        // Work messages
        .init(bundleIDs: ["com.tinyspeck.slackmacgap"], name: "Slack", kind: .writing),
        .init(bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], name: "Microsoft Teams", kind: .writing),
        .init(bundleIDs: ["com.linear"], name: "Linear", kind: .writing),
        // Meetings are work: the call app and its chat belong with Slack and Teams (founder, 2026-10-06).
        .init(bundleIDs: ["us.zoom.xos"], name: "Zoom", kind: .writing),
        .init(bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp"], name: "Webex", kind: .writing),
        // Email
        .init(bundleIDs: ["com.apple.mail"], name: "Mail", kind: .writing),
        .init(bundleIDs: ["com.microsoft.Outlook"], name: "Outlook", kind: .writing),
        .init(bundleIDs: ["com.readdle.SparkDesktop"], name: "Spark", kind: .writing),
        .init(bundleIDs: ["com.superhuman.electron"], name: "Superhuman", kind: .writing),
        .init(bundleIDs: ["com.mimestream.Mimestream"], name: "Mimestream", kind: .writing),
        // Personal messages
        .init(bundleIDs: ["com.apple.MobileSMS"], name: "Messages", kind: .writing),
        .init(bundleIDs: ["net.whatsapp.WhatsApp"], name: "WhatsApp", kind: .writing),
        .init(bundleIDs: ["ru.keepcoder.Telegram"], name: "Telegram", kind: .writing),
        .init(bundleIDs: ["com.hnc.Discord"], name: "Discord", kind: .writing),
        .init(bundleIDs: ["org.whispersystems.signal-desktop"], name: "Signal", kind: .writing),
        // AI tools
        .init(bundleIDs: ["com.anthropic.claudefordesktop"], name: "Claude", kind: .ai),
        .init(bundleIDs: ["com.openai.chat"], name: "ChatGPT", kind: .ai),
        // Everything else
        .init(bundleIDs: ["com.apple.Notes"], name: "Notes", kind: .writing),
        .init(bundleIDs: ["notion.id"], name: "Notion", kind: .writing),
        .init(bundleIDs: ["md.obsidian"], name: "Obsidian", kind: .writing),
        // Code editors and terminals: no tone
        .init(bundleIDs: ["com.todesktop.230313mzl4w4u92"], name: "Cursor", kind: .aiEditor),
        .init(bundleIDs: ["com.exafunction.windsurf"], name: "Windsurf", kind: .aiEditor),
        .init(bundleIDs: ["com.microsoft.VSCode"], name: "Visual Studio Code", kind: .code),
        .init(bundleIDs: ["com.apple.dt.Xcode"], name: "Xcode", kind: .code),
        .init(bundleIDs: ["com.apple.Terminal"], name: "Terminal", kind: .code),
        .init(bundleIDs: ["com.googlecode.iterm2"], name: "iTerm", kind: .code),
    ]

    /// Every installed app from the table, for the Settings list.
    public static func allInstalled(using apps: any InstalledApps) -> [KnownWritingApp] {
        all.filter { app in app.bundleIDs.contains(where: apps.isInstalled) }
    }

    public static func app(forBundleID id: String) -> KnownWritingApp? {
        all.first { $0.bundleIDs.contains(id) }
    }
}

/// One entry in an app's tone menu.
public struct AppToneOption: Identifiable, Equatable, Sendable {
    public enum Value: Hashable, Sendable {
        case useDefault
        case tone(DictationTone)
        case prompt
    }

    public let value: Value
    public let title: String
    /// "Coming" for a choice that is shown but not built yet.
    public let badge: String?
    public let isSelectable: Bool

    public var id: String {
        switch value {
        case .useDefault: "default"
        case .tone(let tone): tone.rawValue
        case .prompt: AppWriting.promptRawValue
        }
    }
}

/// An app's row: what is chosen, what "default" would mean for it, and the menu.
public struct AppToneRow: Identifiable, Equatable, Sendable {
    public let bundleIDs: [String]
    public let name: String
    public let isAI: Bool
    public let selected: AppToneOption.Value
    /// The tone the app gets with no choice of its own.
    public let defaultTone: DictationTone
    /// Where that default comes from: the kind of app, or nil for the overall default.
    public let defaultFrom: StyleContext?
    /// False for a code editor: nothing is applied there.
    public let usesTone: Bool
    public let options: [AppToneOption]

    public var id: String { bundleIDs[0] }

    public var defaultTitle: String { usesTone ? "Default (\(defaultTone.title))" : ToneCopy.noToneInCode }

    /// A short line under the name, only when the default comes from a kind of app that has its own tone.
    public var defaultNote: String? {
        guard selected == .useDefault, usesTone, let from = defaultFrom else { return nil }
        return "\(defaultTone.title), from \(from.title)"
    }

    public static func row(for app: KnownWritingApp, in settings: ToneSettings) -> AppToneRow {
        let id = app.bundleIDs.first { settings.appChoices[$0] != nil } ?? app.id
        let usesTone = app.kind != .aiEditor && app.kind != .code
        let place = app.bundleIDs.compactMap { settings.appKinds[$0] }.first?.place ?? app.context
        let from = place.flatMap { settings.hasOverride(for: $0) ? $0 : nil }
        let tone = place.map(settings.tone(for:)) ?? settings.defaultTone
        let selected: AppToneOption.Value = settings.appTone(for: id).map { .tone($0) } ?? .useDefault
        // A code editor or terminal takes no tone, so it has no menu at all.
        var options: [AppToneOption] = []
        if usesTone {
            options = [AppToneOption(value: .useDefault, title: "Default (\(tone.title))", badge: nil, isSelectable: true)]
                + DictationTone.allCases.map { AppToneOption(value: .tone($0), title: $0.title, badge: nil, isSelectable: true) }
            if app.isAI {
                options.append(AppToneOption(value: .prompt, title: "Prompt", badge: "Coming", isSelectable: false))
            }
        }
        return AppToneRow(bundleIDs: app.bundleIDs, name: app.name, isAI: app.isAI, selected: selected,
                          defaultTone: tone, defaultFrom: from, usesTone: usesTone, options: options)
    }

    public static func rows(for apps: [KnownWritingApp], in settings: ToneSettings) -> [AppToneRow] {
        apps.map { row(for: $0, in: settings) }
    }

    /// Applies a menu pick. A choice that cannot be picked yet changes nothing.
    public static func applying(_ value: AppToneOption.Value, to row: AppToneRow, in settings: ToneSettings) -> ToneSettings {
        guard let option = row.options.first(where: { $0.value == value }), option.isSelectable else { return settings }
        switch value {
        case .useDefault: return settings.settingApp(nil, bundleIDs: row.bundleIDs)
        case .tone(let tone): return settings.settingApp(.tone(tone), bundleIDs: row.bundleIDs)
        case .prompt: return settings
        }
    }

    /// A row for an app the table does not know: one added by hand or found on this Mac. `kind` is where it
    /// is shown; when nil, how dictation in it is classified decides.
    public static func customRow(bundleID: String, name: String, kind: ToneKind? = nil, in settings: ToneSettings) -> AppToneRow {
        let kind = settings.appKinds[bundleID] ?? kind ?? ToneKind.kind(forBundleID: bundleID)
        // A code editor or terminal takes no tone, however it got into the list: no menu, no tone badge,
        // and a tone stored for it earlier is not shown (the plan never applies one there).
        if (kind == .code || AppCategory.classify(bundleID: bundleID) == .code), !AppCategory.isBrowser(bundleID) {
            return AppToneRow(bundleIDs: [bundleID], name: name, isAI: false, selected: .useDefault,
                              defaultTone: settings.defaultTone, defaultFrom: nil, usesTone: false, options: [])
        }
        let place = kind.place
        let from = place.flatMap { settings.hasOverride(for: $0) ? $0 : nil }
        let tone = place.map(settings.tone(for:)) ?? settings.defaultTone
        let selected: AppToneOption.Value = settings.appTone(for: bundleID).map { .tone($0) } ?? .useDefault
        let options = [AppToneOption(value: .useDefault, title: "Default (\(tone.title))", badge: nil, isSelectable: true)]
            + DictationTone.allCases.map { AppToneOption(value: .tone($0), title: $0.title, badge: nil, isSelectable: true) }
        return AppToneRow(bundleIDs: [bundleID], name: name, isAI: false, selected: selected, defaultTone: tone,
                          defaultFrom: from, usesTone: true, options: options)
    }
}
