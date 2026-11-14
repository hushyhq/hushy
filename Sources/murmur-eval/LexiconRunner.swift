import Foundation
import MurmurCore

/// `murmur-eval lexicon [--lists Evals/lexicon-b3a.json] [--verbose]`
///
/// The ordinary-word benchmark of the 2026-10-26 algorithms audit (B3a, B4), before and after the graded lexicon:
/// the system dictionary as the guards used it (lowercase entries of `/usr/share/dict/words`, plus the inflection
/// stripper) against `WordFrequency`. It counts, over invented lists, everyday modern words that are not "ordinary",
/// names and brands that are, rare words that are, and short everyday dictations the drift guard would send to the
/// second recogniser. It also measures what the table costs: the first use, a lookup, and the memory it adds.
/// No audio, no model, no user data.
enum LexiconRunner {
    struct Lists: Decodable {
        let modern: [String]
        let names: [String]
        let archaic: [String]
        let phrases: [String]
    }

    /// What the guards asked before: lowercase-only entries of the system list, inflections accepted, a few function words.
    struct SystemDictionary {
        let words: Set<String>
        init?() {
            guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
            words = Set(text.split(whereSeparator: \.isNewline).compactMap { line in
                line.first?.isLowercase == true ? String(line) : nil
            })
        }
        func isOrdinary(_ word: String) -> Bool { BoostGuard.isEnglishWord(word, in: words) || LearningLexicon.shortFunctionWords.contains(word) }
    }

    static func run(_ args: Arguments) async throws {
        let path = args.string("lists") ?? "Evals/lexicon-b3a.json"
        let lists = try JSONDecoder().decode(Lists.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let verbose = args.flag("verbose")

        let clock = ContinuousClock()
        let rssBefore = residentBytes()
        let firstUse = clock.measure { _ = WordFrequency.shared.entryCount }
        let rssAfter = residentBytes()
        guard let dictionary = SystemDictionary() else { throw EvalError.missing("no /usr/share/dict/words on this Mac: the before column needs it") }
        let rssDictionary = residentBytes()
        var dictionaryLoad = Duration.zero
        for _ in 0..<5 { dictionaryLoad += clock.measure { _ = SystemDictionary() } }

        let now = LearningLexicon.isCommonWord
        let before = dictionary.isOrdinary
        func missing(_ words: [String], _ test: (String) -> Bool) -> [String] { words.filter { !test($0) } }
        func present(_ words: [String], _ test: (String) -> Bool) -> [String] { words.filter(test) }

        let modernBefore = missing(lists.modern, before), modernAfter = missing(lists.modern, now)
        let namesBefore = present(lists.names, before), namesAfter = present(lists.names, now)
        let archaicBefore = present(lists.archaic, before), archaicAfter = present(lists.archaic, now)
        let driftBefore = lists.phrases.filter { AsrDriftGuard.decision(for: $0, englishWords: dictionary.words).needsFallback }
        let driftAfter = lists.phrases.filter { AsrDriftGuard.decision(for: $0).needsFallback }

        print("### Ordinary words · system dictionary → word-frequency table (ordinary from Zipf \(WordFrequency.ordinaryThreshold), known from \(WordFrequency.knownThreshold))\n")
        print("| Test (lists in \(path)) | Before | After |")
        print("|---|---|---|")
        print("| Everyday modern words counted \"not ordinary\" | \(modernBefore.count)/\(lists.modern.count) | \(modernAfter.count)/\(lists.modern.count) |")
        print("| Names, brands and products counted \"ordinary\" | \(namesBefore.count)/\(lists.names.count) | \(namesAfter.count)/\(lists.names.count) |")
        print("| Rare dictionary words counted \"ordinary\" | \(archaicBefore.count)/\(lists.archaic.count) | \(archaicAfter.count)/\(lists.archaic.count) |")
        print("| Everyday short dictations sent to the second recogniser as drift | \(driftBefore.count)/\(lists.phrases.count) | \(driftAfter.count)/\(lists.phrases.count) |")
        do {
            print("\nmodern words still not ordinary: before \(modernBefore.joined(separator: " ")) | after \(modernAfter.joined(separator: " "))")
            print("names counted ordinary: before \(namesBefore.joined(separator: " ")) | after \(namesAfter.joined(separator: " "))")
            print("rare words counted ordinary: before \(archaicBefore.joined(separator: " ")) | after \(archaicAfter.joined(separator: " "))")
            print("drift phrases: before \(driftBefore) | after \(driftAfter)")
        }
        if verbose {
            print("\nGrades (Zipf) of the names: " + lists.names.map { "\($0) \(String(format: "%.2f", WordFrequency.shared.zipf($0)))" }.joined(separator: ", "))
            print("Grades of the modern words: " + lists.modern.map { "\($0) \(String(format: "%.2f", WordFrequency.shared.zipf($0)))" }.joined(separator: ", "))
        }

        // Cost.
        let probes = lists.modern + lists.names + lists.archaic + ["the", "of", "voices", "invited", "stopped", "quickly", "meeting", "xqzv"]
        let rounds = 20_000
        var sink = 0
        let tableTime = clock.measure { for _ in 0..<rounds { for word in probes where WordFrequency.shared.isOrdinary(word) { sink += 1 } } }
        let dictionaryTime = clock.measure { for _ in 0..<rounds { for word in probes where dictionary.isOrdinary(word) { sink += 1 } } }
        let lookups = Double(rounds * probes.count)
        func ns(_ d: Duration) -> Double { Double(d.components.seconds) * 1e9 / lookups + Double(d.components.attoseconds) / 1e9 / lookups }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }
        print("\n| Cost | System dictionary (two sets in the app) | Word-frequency table |")
        print("|---|---|---|")
        print("| First use | \(String(format: "%.1f", ms(dictionaryLoad) / 5)) ms per set (file read and set) | \(String(format: "%.2f", ms(firstUse))) ms (index of \(WordFrequency.shared.entryCount) entries) |")
        print("| One lookup (isOrdinary, mixed words, inflections) | \(String(format: "%.0f", ns(dictionaryTime))) ns | \(String(format: "%.0f", ns(tableTime))) ns |")
        print("| Resident memory added | \(mb(rssDictionary - rssAfter)) MB per set | \(mb(rssAfter - rssBefore)) MB (the table itself is \(WordFrequency.shared.tableByteCount / 1024) KB in the binary) |")
        if sink < 0 { print(sink) }
    }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
