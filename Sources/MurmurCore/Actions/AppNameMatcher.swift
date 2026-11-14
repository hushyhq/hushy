import Foundation

/// Finds the installed app a spoken name means. Pure: the caller (`WorkspaceLinkBackend`) lists
/// the apps it can see — running ones, `/Applications`, `~/Applications`, the system folders —
/// and this picks one, or nothing.
///
/// Speech gives short, casual names and the odd mishearing: "Chrome" for Google Chrome, "code"
/// for Visual Studio Code, "anti gravity" for Antigravity IDE, "cloud" for Claude. So the match
/// runs from strict to loose — exact, a known alias, a whole word of the name, a prefix, a
/// close spelling, the same consonants — and stops at the first level that finds something.
/// Names that are plainly not what anyone asks to open (helpers, updaters, URL handlers) are
/// left out before matching, so "Claude" can never land on "Claude Code URL Handler".
public enum AppNameMatcher {
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let bundleID: String?

        public init(name: String, bundleID: String? = nil) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    /// Spoken shorthand → the app's real name(s), first preferred.
    public static let aliases: [String: [String]] = [
        "chrome": ["Google Chrome"], "google": ["Google Chrome"],
        "code": ["Visual Studio Code"], "vs code": ["Visual Studio Code"], "vscode": ["Visual Studio Code"],
        "anti gravity": ["Antigravity", "Antigravity IDE"], "antigravity": ["Antigravity", "Antigravity IDE"],
        "cloud": ["Claude"], "claud": ["Claude"], "clawed": ["Claude"],
        "chat gpt": ["ChatGPT"], "chat gbt": ["ChatGPT"], "gpt": ["ChatGPT"],
        "word": ["Microsoft Word"], "excel": ["Microsoft Excel"], "powerpoint": ["Microsoft PowerPoint"],
        "outlook": ["Microsoft Outlook"], "teams": ["Microsoft Teams"], "edge": ["Microsoft Edge"],
        "zoom": ["zoom.us", "Zoom"], "brave": ["Brave Browser"], "arc": ["Arc"],
        "iterm": ["iTerm", "iTerm2"], "terminal": ["Terminal", "Ghostty", "iTerm"],
        "settings": ["System Settings"], "system settings": ["System Settings"],
        "preferences": ["System Settings"], "system preferences": ["System Settings"],
        "imessage": ["Messages"], "texts": ["Messages"], "itunes": ["Music"], "things": ["Things3", "Things"],
        "intellij": ["IntelliJ IDEA"], "pycharm": ["PyCharm"], "webstorm": ["WebStorm"],
        "one password": ["1Password"], "1 password": ["1Password"], "activity monitor": ["Activity Monitor"],
    ]

    /// Bundle identifiers the OS can resolve for the most-asked apps, keyed by normalized name.
    /// A hit here opens the app even when its folder isn't one the scan looks in.
    public static let bundleIDs: [String: String] = [
        "googlechrome": "com.google.Chrome", "safari": "com.apple.Safari", "finder": "com.apple.finder",
        "systemsettings": "com.apple.systempreferences", "terminal": "com.apple.Terminal",
        "mail": "com.apple.mail", "messages": "com.apple.MobileSMS", "calendar": "com.apple.iCal",
        "notes": "com.apple.Notes", "reminders": "com.apple.reminders", "music": "com.apple.Music",
        "photos": "com.apple.Photos", "facetime": "com.apple.FaceTime", "maps": "com.apple.Maps",
        "preview": "com.apple.Preview", "activitymonitor": "com.apple.ActivityMonitor",
        "visualstudiocode": "com.microsoft.VSCode", "slack": "com.tinyspeck.slackmacgap",
        "claude": "com.anthropic.claudefordesktop", "chatgpt": "com.openai.chat",
        "firefox": "org.mozilla.firefox", "arc": "company.thebrowser.Browser", "bravebrowser": "com.brave.Browser",
        "microsoftedge": "com.microsoft.edgemac", "microsoftteams": "com.microsoft.teams2",
        "zoomus": "us.zoom.xos", "notion": "notion.id", "figma": "com.figma.Desktop", "spotify": "com.spotify.client",
        "discord": "com.hnc.Discord", "whatsapp": "net.whatsapp.WhatsApp", "xcode": "com.apple.dt.Xcode",
    ]

    /// Names nobody asks to open by voice: they'd only ever be fuzzy false positives.
    static let excludedWords = ["handler", "helper", "uninstall", "uninstaller", "updater", "agent", "daemon", "installer", "crash", "reporter"]

    /// Lowercase letters and digits only: "Visual Studio Code" → "visualstudiocode".
    public static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Spaces kept, everything else dropped: "Anti-Gravity" → "anti gravity" (for the aliases).
    static func spokenForm(_ name: String) -> String {
        name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The bundle identifier `bundleIDs` knows for a spoken name (directly or through an alias).
    public static func knownBundleID(for spoken: String) -> String? {
        for name in namesToTry(spoken) {
            if let id = bundleIDs[normalize(name)] { return id }
        }
        return nil
    }

    /// The names worth looking for: what was said, then its aliases.
    static func namesToTry(_ spoken: String) -> [String] {
        let form = spokenForm(spoken)
        let normalized = normalize(spoken)
        var names = [spoken]
        for (alias, targets) in aliases where spokenForm(alias) == form || normalize(alias) == normalized {
            names += targets
        }
        return names
    }

    /// The candidate `spoken` means, or nil when nothing is close enough to open safely.
    public static func best(spoken: String, among candidates: [Candidate]) -> Candidate? {
        let usable = usableCandidates(candidates)
        guard !usable.isEmpty, !normalize(spoken).isEmpty else { return nil }
        // What was said, and then what is left after any filler or polite lead-in ("um slack",
        // "please safari"), as `AskRouter.frame` drops them in front of every command. A real name
        // wins first, whole, so "Quick Look" and "Just Press Record" stay what they are.
        // Every match level is finished for the whole phrase before the stripped one is tried at
        // all, so "quick look" never becomes the app called "Look" while Quick Look Pro is installed.
        for form in [spoken] + leadInFree(spoken) {
            if let match = matching(form, in: usable) { return match }
        }
        return nil
    }

    /// One phrase through every level: exact, whole word, prefix, spelling, sound.
    private static func matching(_ form: String, in usable: [Candidate]) -> Candidate? {
        for name in namesToTry(form) {
            if let match = exact(name, in: usable) { return match }
        }
        for name in namesToTry(form) {
            if let match = byWord(name, in: usable) ?? byPrefix(name, in: usable) { return match }
        }
        return bySpelling(form, in: usable) ?? bySound(form, in: usable)
    }

    /// `spoken` without the lead-ins in front of it, when there are any and something remains.
    static func leadInFree(_ spoken: String) -> [String] {
        let bare = AskRouter.frame(spoken)
        return bare.isEmpty || bare == AskRouter.normalize(spoken) ? [] : [bare]
    }

    /// The candidates worth matching: helpers, updaters and URL handlers left out.
    public static func usableCandidates(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { candidate in
            let words = Set(spokenForm(candidate.name).split(separator: " ").map(String.init))
            return words.isDisjoint(with: excludedWords)
        }
    }

    static func exact(_ name: String, in candidates: [Candidate]) -> Candidate? {
        let wanted = normalize(name)
        return candidates.first { normalize($0.name) == wanted }
    }

    /// "chrome" is a whole word of "Google Chrome"; at most two other words, so a long helper
    /// name never wins on one shared word. The shortest name wins.
    static func byWord(_ name: String, in candidates: [Candidate]) -> Candidate? {
        let wanted = spokenForm(name)
        guard wanted.count >= 3 else { return nil }
        let hits = candidates.filter { candidate in
            let words = spokenForm(candidate.name).split(separator: " ").map(String.init)
            return words.count <= 3 && words.contains(wanted)
        }
        return hits.min { $0.name.count < $1.name.count }
    }

    /// "antigravity" starts "Antigravity IDE"; "zoom" starts "zoom.us". Four letters at least.
    static func byPrefix(_ name: String, in candidates: [Candidate]) -> Candidate? {
        let wanted = normalize(name)
        guard wanted.count >= 4 else { return nil }
        let hits = candidates.filter { normalize($0.name).hasPrefix(wanted) }
        return hits.min { $0.name.count < $1.name.count }
    }

    /// One or two letters off ("figna" → Figma, "chrom" → Chrome), on names of four letters or
    /// more; the closest wins.
    static func bySpelling(_ spoken: String, in candidates: [Candidate]) -> Candidate? {
        let wanted = normalize(spoken)
        guard wanted.count >= 4 else { return nil }
        let allowed = wanted.count >= 8 ? 2 : 1
        var bestMatch: (Candidate, Int)?
        for candidate in candidates {
            for name in [normalize(candidate.name)] + spokenForm(candidate.name).split(separator: " ").map(String.init) {
                guard abs(name.count - wanted.count) <= allowed else { continue }
                let distance = editDistance(wanted, name)
                if distance <= allowed, bestMatch.map({ distance < $1 }) ?? true { bestMatch = (candidate, distance) }
            }
        }
        return bestMatch?.0
    }

    /// The same consonants in the same order ("cloud" and "Claude" are both c-l-d): phonetic
    /// tolerance for names speech recognition respells. Whole names only, four letters or more.
    static func bySound(_ spoken: String, in candidates: [Candidate]) -> Candidate? {
        let wanted = skeleton(spoken)
        guard normalize(spoken).count >= 4, wanted.count >= 2 else { return nil }
        let hits = candidates.filter { candidate in
            let name = normalize(candidate.name)
            return abs(name.count - normalize(spoken).count) <= 2 && skeleton(candidate.name) == wanted
        }
        return hits.min { $0.name.count < $1.name.count }
    }

    /// Consonants with doubles collapsed and a few sound-alikes folded (ph→f, ck→k, c→k before
    /// a, o, u; z→s; the leading vowel kept so "Arc" and "Rc" differ).
    static func skeleton(_ name: String) -> String {
        var text = normalize(name).replacingOccurrences(of: "ph", with: "f").replacingOccurrences(of: "ck", with: "k")
        text = text.replacingOccurrences(of: "ca", with: "ka").replacingOccurrences(of: "co", with: "ko")
            .replacingOccurrences(of: "cu", with: "ku").replacingOccurrences(of: "z", with: "s")
        var out = ""
        for (index, char) in text.enumerated() {
            let isVowel = "aeiouy".contains(char)
            if isVowel, index > 0 { continue }
            if let last = out.last, last == char { continue }
            out.append(char)
        }
        return out
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var previousPrevious = previous
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                // A swapped pair ("figam" for "figma") counts as one edit.
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previousPrevious[j - 2] + 1)
                }
            }
            previousPrevious = previous
            previous = current
        }
        return previous[b.count]
    }
}
