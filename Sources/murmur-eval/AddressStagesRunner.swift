import Foundation
import MurmurCore

/// `murmur-eval address-stages [--backend apple|none|local] [--bundle id] [--passes N] [--path release|prewarmed|both]`
///
/// Text only, invented names. Pushes address-shaped recogniser text (a mis-heard two-word name, then "com", "dot com",
/// ".com", with and without a full stop, and some clean ones) through the stages after the recogniser, one at a time:
/// the rules draft, then the whole cleanup pass (the model and its checks) as the app runs it. The first pass of the
/// process is the cold one. Each line says whether a stage's output ends in a token repeated more than the stage's input did.
enum AddressStagesRunner {
    /// Recogniser-shaped texts: two mis-heard words then a bare "com", the spoken and written forms, and clean ones.
    static let inputs: [String] = [
        "Jimmy lord com.", "Jimmy lord com", "Jimmy lord dot com.", "Jimmy lord dot com", "Jimmy lord.com.", "Jimmy lord. com.",
        "Jimmy lord, com.", "Jimmy lordcom.", "jimmylord.com", "Dana pike com.", "Dana Pike dot com", "Ravi stone com.",
        "Mira holt dot org.", "Tom brandt net.", "Tom brandt dot net", "go to example dot com", "go to example.com",
        "open dana pike dot com please", "Jimmy Lord", "lord com", "lord dot com", "com", "dot com", "Dana Pike.com.",
        // A dictation that is only an address, with a subdomain, a path, an email, a capital and a full stop from the recogniser.
        "Jimmylord.com.", "mail dot example dot org", "Mail.example.org.", "example dot com slash pricing", "Example.com/pricing.",
        "jordan at example dot com", "Jordan@example.com.", "www dot miraholt dot com",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// The longest run of one token repeated back to back.
    static func longestRun(_ text: String) -> Int {
        var best = 0, run = 0
        var last: String?
        for token in tokens(text) {
            run = token == last ? run + 1 : 1
            last = token
            best = max(best, run)
        }
        return best
    }

    static func run(_ args: Arguments) async throws {
        let bundle = args.string("bundle") ?? "com.apple.Safari"
        let passes = args.int("passes") ?? 2
        let (settings, category) = LiveShapeRunner.settings(tone: .professional, bundleID: bundle)
        print("### Address stages · \(bundle) → \(category.rawValue) · level \(settings.cleanupOptions.level.rawValue) · backend \(args.string("backend") ?? "apple")")
        for pass in 1...passes {
            // A fresh cleaner each pass, a shared model: pass 1 is the cold first call of the process.
            let cleaner = args.makeCleaner(retainsRejectedCandidates: true)
            let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
            for input in inputs {
                let rules = TextCleaner(options: settings.cleanupOptions).clean(input).text
                let started = ContinuousClock.now
                let result = await pipeline.clean(input, settings: settings, released: started)
                let waited = ModelPace.ms(ContinuousClock.now - started)
                let groups = result.groups.map {
                    "\($0.outcome.rawValue)\($0.guardCode.map { "/\($0.rawValue)" } ?? "") \($0.modelMs.map { "\($0)ms" } ?? "-")"
                        + ($0.repairedSpans > 0 ? " repaired:\($0.repairedSpans)" : "")
                }.joined(separator: " · ")
                let base = longestRun(input)
                let flag = longestRun(rules) > base ? " RULES-REPEAT" : ""
                let out = longestRun(result.text) > base ? " OUTPUT-REPEAT" : ""
                print("[pass \(pass)] in=\"\(input)\" rules=\"\(rules)\" out=\"\(result.text)\" \(waited)ms [\(groups)]\(flag)\(out)")
                for group in result.groups {
                    if let rejected = group.rejectedCandidate {
                        let marker = longestRun(rejected) > base ? " MODEL-REPEAT" : ""
                        print("    rejected answer=\"\(rejected)\"\(marker)")
                    }
                }
            }
        }
    }
}
