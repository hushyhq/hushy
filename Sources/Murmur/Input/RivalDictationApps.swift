import Foundation

/// A dictation app that other people run and that may listen on the key Hushy listens on. Two
/// apps on one key type one dictation twice. Plain data: the table below is read, never learned.
struct RivalDictationApp: Equatable, Sendable {
    /// Stable slug. Stored when the person keeps their key, and the only name that goes in logs.
    let id: String
    /// Shown only when `RivalKeyCopy.namesRivals` is on (legal and founder sign-off pending).
    let name: String
    let bundleIDs: [String]
    /// The hold-to-talk key the app ships with on a Mac. Empty when the person always picks one
    /// or when no published default was found.
    let defaultKeys: Set<TriggerKey>
    let keySource: String
    let bundleIDSource: String
}

/// What Hushy shows when a running rival shares the dictation key.
struct RivalKeyOffer: Equatable {
    let rivals: [RivalDictationApp]
    let current: TriggerKey
    let suggested: TriggerKey
}

enum RivalDictationApps {
    /// Checked 2026-11-07. A default can change in a rival's release, and a person can rebind it, so
    /// this says "may share the key", never "does". Granola's voice typing is a setting inside a
    /// meeting app that is often running, so for Granola a running app is only a hint.
    static let table: [RivalDictationApp] = [
        RivalDictationApp(
            id: "wispr-flow", name: "Wispr Flow", bundleIDs: ["com.electron.wispr-flow"], defaultKeys: [.fn],
            keySource: "https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation",
            bundleIDSource: "CFBundleIdentifier of /Applications/Wispr Flow.app, read 2026-11-07"),
        RivalDictationApp(
            id: "granola", name: "Granola", bundleIDs: ["com.granola.app"], defaultKeys: [.fn],
            keySource: "https://docs.granola.ai/help-center/voice-typing/troubleshooting-dictation",
            bundleIDSource: "https://formulae.brew.sh/api/cask/granola.json"),
        RivalDictationApp(
            id: "superwhisper", name: "Superwhisper", bundleIDs: ["com.superduper.superwhisper"], defaultKeys: [.rightCommand],
            keySource: "https://superwhisper.com/docs/get-started/quickstart",
            bundleIDSource: "https://formulae.brew.sh/api/cask/superwhisper.json"),
        RivalDictationApp(
            id: "macwhisper", name: "MacWhisper", bundleIDs: ["com.goodsnooze.MacWhisper"], defaultKeys: [],
            keySource: "https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature",
            bundleIDSource: "https://formulae.brew.sh/api/cask/macwhisper.json"),
        RivalDictationApp(
            id: "aqua-voice", name: "Aqua Voice", bundleIDs: ["com.electron.aqua-voice"], defaultKeys: [.fn],
            keySource: "https://aquavoice.com/info/faq",
            bundleIDSource: "https://formulae.brew.sh/api/cask/aqua-voice.json (cache folder name)"),
        RivalDictationApp(
            id: "hush", name: "Hush", bundleIDs: ["com.hush.software", "com.djmunro.hush"], defaultKeys: [.fn],
            keySource: "https://www.hush.software/faq and https://github.com/djmunro/hush",
            bundleIDSource: "src-tauri/tauri.conf.json of github.com/DeepanshuPal/hush; README of github.com/djmunro/hush"),
        RivalDictationApp(
            id: "speakoflow", name: "SpeakoFlow", bundleIDs: ["com.abhishekbarali.speakoflow"], defaultKeys: [.fn],
            keySource: "https://www.speakoflow.com/docs/start/keyboard-shortcuts",
            bundleIDSource: "src-tauri/tauri.conf.json of github.com/AbhishekBarali/SpeakoFlow"),
        RivalDictationApp(
            id: "eloquent", name: "Eloquent", bundleIDs: ["com.google.AIEdgeEloquent"], defaultKeys: [],
            keySource: "https://developers.google.com/edge/eloquent (hotkey is customizable; no default published)",
            bundleIDSource: "Application Support folder name, mactechnews.de, 2026-06; unconfirmed on a device"),
    ]

    /// Keys with a published rival default. A suggested key avoids all of them, so a rival that
    /// launches later does not collide with the key the person just moved to.
    static var claimedKeys: Set<TriggerKey> { table.reduce(into: []) { $0.formUnion($1.defaultKeys) } }

    /// Tried in this order. Right Option is no rival's default; Control + Option is Wispr's key on
    /// a Mac with no fn key; Right Command is Superwhisper's.
    static let alternatives: [TriggerKey] = [.rightOption, .controlOption, .rightCommand]

    /// The running rivals whose default key is `trigger`, in table order.
    static func collisions(running: Set<String>, trigger: TriggerKey) -> [RivalDictationApp] {
        table.filter { app in
            app.defaultKeys.contains(trigger) && !running.isDisjoint(with: app.bundleIDs)
        }
    }

    /// The key to offer instead of `current`: unclaimed first, then any that no running rival uses.
    static func suggestedKey(replacing current: TriggerKey, running: Set<String>) -> TriggerKey? {
        let claimed = claimedKeys
        let usedNow = table.filter { !running.isDisjoint(with: $0.bundleIDs) }
            .reduce(into: Set<TriggerKey>()) { $0.formUnion($1.defaultKeys) }
        let open = alternatives.filter { $0 != current }
        return open.first { !claimed.contains($0) } ?? open.first { !usedNow.contains($0) }
    }

    /// The offer to show, or nil when nothing shares the key, the person already chose to keep it
    /// for every rival that does, or there is no key to move to.
    static func offer(running: Set<String>, trigger: TriggerKey, dismissed: Set<String>) -> RivalKeyOffer? {
        let open = collisions(running: running, trigger: trigger).filter { !dismissed.contains($0.id) }
        guard !open.isEmpty, let next = suggestedKey(replacing: trigger, running: running) else { return nil }
        return RivalKeyOffer(rivals: open, current: trigger, suggested: next)
    }
}
