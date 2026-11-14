import XCTest
@testable import MurmurCore

/// The paste matrix: for 30 Mac apps, what Hushy's delivery code does when the paste lands or is lost and
/// the field can or cannot be read. Nothing here launches an app. Each app is placed in the accessibility
/// surface its toolkit is known for (`Surface`), the surface's key-down facts go through the real
/// `FocusAnswer.classify`, and the paste goes through the real `TargetedDelivery` and `LandingEvidence`
/// with a scripted field. What the table cannot say is whether an app really exposes the facts its
/// surface lists; that placement is the one thing modelled, and every row says so.
///
/// One surface is modelled because it breaks the obvious reading of a field: the text area behind a hidden
/// input (the helper textarea of xterm.js in the terminal panels of VS Code and Cursor, Monaco's input area).
/// Accessibility reports a text area there, so the answer is `field`, but its count stays empty whether the
/// paste landed or not. Such apps must never be called lost on that evidence (`FieldWatch.watches`).
enum PasteMatrix {
    /// What a toolkit hands to the accessibility API for the focused element at key-down.
    enum Surface: String, CaseIterable {
        case appKitText = "AppKit text view"
        case webKitText = "WebKit text input"
        case terminalText = "Terminal text area"
        case chromiumWeb = "Chromium or Electron web content"
        case geckoWeb = "Gecko web content"
        case customEditor = "Custom-drawn text editor"
        case gpuTerminal = "GPU-drawn terminal"
        case canvasApp = "Canvas app with web text"
        case electronTextArea = "Electron text area behind a hidden input"

        var role: String? {
            switch self {
            case .appKitText, .webKitText, .terminalText, .electronTextArea: "AXTextArea"
            case .chromiumWeb, .geckoWeb: "AXWebArea"
            case .customEditor, .canvasApp: "AXGroup"
            case .gpuTerminal: nil
            }
        }

        var valueSettable: Bool { self == .appKitText || self == .webKitText || self == .electronTextArea }
        var hasSelectedTextRange: Bool {
            self == .appKitText || self == .webKitText || self == .terminalText || self == .electronTextArea
        }

        /// Whether the count of the focused text area follows what is pasted. The hidden input's does not.
        var countFollowsPaste: Bool { self != .electronTextArea }

        /// Whether a count or caret read of the field is expected to work, as modelled.
        var fieldReads: String {
            switch self {
            case .appKitText, .webKitText, .terminalText: "yes"
            case .electronTextArea: "yes, but it stays empty"
            case .chromiumWeb, .geckoWeb: "sometimes"
            case .customEditor, .gpuTerminal, .canvasApp: "no"
            }
        }
    }

    struct App {
        let name: String
        let bundleID: String
        let surface: Surface
        var isWatched: Bool { FieldWatch.watches(bundleID: bundleID) }
    }

    /// The 30 apps most likely to matter for dictation on a Mac: chat, mail, notes, documents, browsers,
    /// editors, terminals and the AI apps. Chosen by likely use, not measured use.
    static let apps: [App] = [
        App(name: "Google Chrome", bundleID: "com.google.Chrome", surface: .chromiumWeb),
        App(name: "Safari", bundleID: "com.apple.Safari", surface: .webKitText),
        App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", surface: .chromiumWeb),
        App(name: "Notes", bundleID: "com.apple.Notes", surface: .appKitText),
        App(name: "Mail", bundleID: "com.apple.mail", surface: .webKitText),
        App(name: "Messages", bundleID: "com.apple.MobileSMS", surface: .appKitText),
        App(name: "Microsoft Outlook", bundleID: "com.microsoft.Outlook", surface: .customEditor),
        App(name: "Microsoft Word", bundleID: "com.microsoft.Word", surface: .customEditor),
        App(name: "Microsoft Teams", bundleID: "com.microsoft.teams2", surface: .chromiumWeb),
        App(name: "Zoom chat", bundleID: "us.zoom.xos", surface: .customEditor),
        App(name: "Discord", bundleID: "com.hnc.Discord", surface: .chromiumWeb),
        App(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", surface: .appKitText),
        App(name: "Telegram", bundleID: "ru.keepcoder.Telegram", surface: .appKitText),
        App(name: "Notion", bundleID: "notion.id", surface: .chromiumWeb),
        App(name: "Obsidian", bundleID: "md.obsidian", surface: .chromiumWeb),
        App(name: "Linear", bundleID: "com.linear", surface: .chromiumWeb),
        App(name: "Figma", bundleID: "com.figma.Desktop", surface: .canvasApp),
        App(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", surface: .electronTextArea),
        App(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", surface: .electronTextArea),
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode", surface: .appKitText),
        App(name: "Terminal", bundleID: "com.apple.Terminal", surface: .terminalText),
        App(name: "iTerm2", bundleID: "com.googlecode.iterm2", surface: .gpuTerminal),
        App(name: "Ghostty", bundleID: "com.mitchellh.ghostty", surface: .gpuTerminal),
        App(name: "Warp", bundleID: "dev.warp.Warp-Stable", surface: .gpuTerminal),
        App(name: "Claude desktop", bundleID: "com.anthropic.claudefordesktop", surface: .chromiumWeb),
        App(name: "ChatGPT desktop", bundleID: "com.openai.chat", surface: .customEditor),
        App(name: "Pages", bundleID: "com.apple.iWork.Pages", surface: .customEditor),
        App(name: "TextEdit", bundleID: "com.apple.TextEdit", surface: .appKitText),
        App(name: "Arc", bundleID: "company.thebrowser.Browser", surface: .chromiumWeb),
        App(name: "Firefox", bundleID: "org.mozilla.firefox", surface: .geckoWeb),
    ]

    /// Whether ⌘V reached the field, and whether Hushy can read the field.
    struct Scenario: Hashable {
        let lands: Bool
        let readable: Bool

        static let all = [
            Scenario(lands: true, readable: true), Scenario(lands: true, readable: false),
            Scenario(lands: false, readable: true), Scenario(lands: false, readable: false),
        ]
        var title: String { "\(lands ? "lands" : "lost"), \(readable ? "reads" : "unreadable")" }
    }

    /// Where the words are at the end, in the order of how well the person is told.
    enum Outcome: String {
        /// The field showed the paste. The earlier clipboard came back.
        case confirmed = "C"
        /// The paste was lost and Hushy saw it: the card opens, the words are on the clipboard and in History.
        case caught = "D"
        /// The paste could not be read back: the words stay on the clipboard and a quiet row says so.
        case keptOnClipboard = "K"
        /// Reported as pasted and never checked: the earlier clipboard came back, so the words are only in History.
        case historyOnly = "H"
        /// The words went to the clipboard and the card, not the field.
        case copied = "P"
        /// A password field: the words are held in History, never put on the clipboard.
        case held = "S"
    }

    struct Run {
        let answer: FocusAnswer
        let outcome: Outcome
    }

    @MainActor
    static func run(_ app: App, _ scenario: Scenario) async -> Run {
        let answer = FocusAnswer.classify(
            role: app.surface.role, subrole: nil, valueSettable: app.surface.valueSettable,
            hasSelectedTextRange: app.surface.hasSelectedTextRange, bundleID: app.bundleID)
        let key = Memo(answer: answer, isWatched: app.isWatched, countFollowsPaste: app.surface.countFollowsPaste, scenario: scenario)
        if let known = memo[key] { return Run(answer: answer, outcome: known) }
        let outcome = await deliver(answer: answer, scenario: scenario, secure: false, bundleID: app.bundleID,
                                    countFollowsPaste: app.surface.countFollowsPaste)
        memo[key] = outcome
        return Run(answer: answer, outcome: outcome)
    }

    /// The delivery code sees only the answer, whether the app is watched and the field, never the app, so apps
    /// that classify alike share a run.
    private struct Memo: Hashable {
        let answer: FocusAnswer
        let isWatched: Bool
        let countFollowsPaste: Bool
        let scenario: Scenario
    }

    @MainActor private static var memo: [Memo: Outcome] = [:]

    /// One paste of `text` through the real delivery code into a scripted field. The field is read once at
    /// key-down, as the app reads it (`FieldWatch.baseline`), and not again until the second look.
    @MainActor
    static func deliver(answer: FocusAnswer, scenario: Scenario, secure: Bool, moved: Bool = false,
                        pasteKeySucceeds: Bool = true, text: String = "Ship it on Thursday.",
                        bundleID: String? = "com.apple.TextEdit", countFollowsPaste: Bool = true) async -> Outcome {
        let focus = FakeFocus()
        if secure { focus.security[100] = .secure }
        let bound = focus.bind()
        if moved { focus.switchToChat() }
        let paster = FakePaster()
        paster.pasteKeySucceeds = pasteKeySucceeds
        var fieldCount = 10
        paster.afterStaging = { if scenario.lands && countFollowsPaste { fieldCount += text.utf16.count } }
        let read: () -> LandingProbe? = {
            scenario.readable ? LandingProbe(characterCount: fieldCount, selectedLength: 0, caretLocation: fieldCount) : nil
        }
        var watch: FieldPasteWatch?
        let baseline = FieldWatch.baseline(answer: answer, bundleID: bundleID, forDictation: true, read: read)
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: false, answer: answer,
            check: { TargetGuard.check(bound, reader: focus) }, landing: read, paster: paster,
            fieldBaseline: baseline, onFieldPaste: { watch = $0 })
        var late: LateLanding?
        if let watch { late = await TargetedDelivery.lateLanding(watch, read: read) }
        paster.settle()
        let onClipboard = paster.clipboard == text
        switch result {
        case .unknownConfirmed, .unknownConfirmedReturnSkipped: return .confirmed
        case .unknownNotLanded: return .caught
        case .unknownUnreadable, .unknownUnreadableReturnSkipped: return .keptOnClipboard
        case .pasted:
            switch late {
            case .confirmed: return .confirmed
            case .notLanded: return .caught
            case .unreadable, nil: return onClipboard ? .keptOnClipboard : .historyOnly
            }
        case .heldForSecureField: return .held
        case .copied, .noField, .dispatchFailed: return onClipboard ? .copied : .historyOnly
        default: return onClipboard ? .copied : .historyOnly
        }
    }

    // MARK: The table

    static let markerStart = "<!-- paste-matrix:start -->"
    static let markerEnd = "<!-- paste-matrix:end -->"

    @MainActor
    static func markdown() async -> String {
        var lines = [
            "| App | Category | Surface (modelled) | Key-down answer | Field reads | " + Scenario.all.map(\.title).joined(separator: " | ") + " |",
            "|---|---|---|---|---|" + String(repeating: "---|", count: Scenario.all.count),
        ]
        for app in apps {
            var cells: [String] = []
            var answer = FocusAnswer.unknown
            for scenario in Scenario.all {
                let run = await run(app, scenario)
                answer = run.answer
                cells.append(run.outcome.rawValue)
            }
            let category = AppCategory.classify(bundleID: app.bundleID).title
            lines.append("| \(app.name) | \(category) | \(app.surface.rawValue) | \(answer.rawValue) | \(app.surface.fieldReads) | " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}
