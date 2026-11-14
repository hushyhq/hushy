@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Measures the NBA domain pack as recogniser vocabulary (`PersonalLexicon`, `DomainPack`):
///
///   murmur-eval lexicon-pack [--voices Karen,Daniel,Moira] [--model ultra]
///   murmur-eval lexicon-pack --rows Evals/accuracy-v1.jsonl   (the accuracy eval's rows: `LexiconRowsRunner`)
///
/// Speech comes from macOS `say` (no microphone, no recordings), fed to the recogniser with the app's vocabulary
/// boost and `BoostGuard` (`Engine.transcribe(_:vocabulary:)`). It measures the recogniser step only, not cleanup.
/// Three conditions on the same audio:
///   none     the vocabulary every dictation has on main (no lexicon terms: what a person without evidence gets);
///   pack     the pack switched on with no personal sightings (the pack's most written-about names);
///   fan      the pack on after History mentioned the players in these sentences (the person's own players first).
/// Groups: athletes (term exact = the pack's spelling or one of its aliases, case-sensitive) and harm rows (ordinary
/// sentences, several with words close to a player's name: every word that differs from `none` is a swap).
/// Every sentence is invented for this runner; the names are public.
enum LexiconPackRunner {
    struct AthleteRow { let sentence: String; let name: String }

    static let athletes: [AthleteRow] = [
        .init(sentence: "Victor Wembanyama blocked six shots last night.", name: "Victor Wembanyama"),
        .init(sentence: "I think Wembanyama will win defensive player of the year.", name: "Victor Wembanyama"),
        .init(sentence: "Giannis Antetokounmpo is unstoppable in transition.", name: "Giannis Antetokounmpo"),
        .init(sentence: "Shai Gilgeous-Alexander dropped forty against Denver.", name: "Shai Gilgeous-Alexander"),
        .init(sentence: "Nikola Jokic had another triple double.", name: "Nikola Jokić"),
        .init(sentence: "Luka Doncic hit the game winner from the logo.", name: "Luka Dončić"),
        .init(sentence: "Joel Embiid is listed as questionable tonight.", name: "Joel Embiid"),
        .init(sentence: "Tyrese Haliburton led the break all game.", name: "Tyrese Haliburton"),
        .init(sentence: "Paolo Banchero looks like a future MVP.", name: "Paolo Banchero"),
        .init(sentence: "Cade Cunningham carried the Pistons again.", name: "Cade Cunningham"),
        .init(sentence: "Alperen Sengun posted up all night.", name: "Alperen Şengün"),
        .init(sentence: "Kristaps Porzingis came off the bench.", name: "Kristaps Porziņģis"),
        .init(sentence: "Domantas Sabonis grabbed twenty rebounds.", name: "Domantas Sabonis"),
        .init(sentence: "Chet Holmgren and Wembanyama are a fun matchup.", name: "Chet Holmgren"),
        .init(sentence: "Tyrese Maxey scored thirty in the first half.", name: "Tyrese Maxey"),
        .init(sentence: "Jalen Brunson is clutch in the fourth quarter.", name: "Jalen Brunson"),
        .init(sentence: "Zion Williamson finally looks healthy.", name: "Zion Williamson"),
        .init(sentence: "Scoot Henderson needs more minutes.", name: "Scoot Henderson"),
        .init(sentence: "Amen Thompson guards all five positions.", name: "Amen Thompson"),
        .init(sentence: "Cooper Flagg was the first pick in the draft.", name: "Cooper Flagg"),
        .init(sentence: "Zaccharie Risacher shot well from the corner.", name: "Zaccharie Risacher"),
        .init(sentence: "Lauri Markkanen is an underrated scorer.", name: "Lauri Markkanen"),
        .init(sentence: "Franz Wagner drove to the rim every time.", name: "Franz Wagner"),
        .init(sentence: "Bam Adebayo switched onto the point guard.", name: "Bam Adebayo"),
        .init(sentence: "Anthony Edwards dunked over two defenders.", name: "Anthony Edwards"),
        .init(sentence: "De'Aaron Fox is the fastest guard in the league.", name: "De'Aaron Fox"),
        .init(sentence: "Jaren Jackson Jr. had five blocks.", name: "Jaren Jackson Jr."),
        .init(sentence: "Jusuf Nurkic set a hard screen.", name: "Jusuf Nurkić"),
        .init(sentence: "Dyson Daniels leads the league in steals.", name: "Dyson Daniels"),
        .init(sentence: "Deni Avdija had a career night.", name: "Deni Avdija"),
    ]

    /// Ordinary sentences that must come back the same with the pack on. Several sit close to a player's name.
    static let harm: [String] = [
        "Let's go green with the new office plan.", "The curry was too spicy for me.", "He is as quick as a fox.",
        "I need a holiday after this week.", "Can you send me the next steps?", "We should hold the meeting on Friday.",
        "The young players need more time.", "Put the brown box on the table.", "That was a bold move by the team.",
        "Please text me when you land.", "Turn left at the second light.", "The ball rolled under the couch.",
        "My brother lives in Denver now.", "Order some ice for the party.", "We won the game by three points.",
        "Let me check the price before we buy it.", "The jazz concert starts at eight.", "I love the heat in summer.",
        "She plays the cello every morning.", "Add milk and bread to the list.",
    ]

    static func run(_ args: Arguments) async throws {
        if let rows = args.string("rows") { return try await LexiconRowsRunner.run(args, path: rows) }
        let voices = (args.string("voices") ?? "Karen,Daniel,Moira").split(separator: ",").map(String.init)
        let engine = try await Engine.load(args.model)
        guard let nba = DomainPackCatalog.pack(id: "sports.nba") else { throw EvalError.missing("sports.nba pack") }
        let conditions = [("none", PipelineSettings().vocabulary), ("pack", vocabulary(nba, fan: false)), ("fan", vocabulary(nba, fan: true))]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        print("### NBA pack as vocabulary · \(nba.terms.count) pack terms · voices \(voices.joined(separator: ", "))")
        for (name, context) in conditions { print("- \(name): \(context.terms.count) vocabulary terms") }

        var exact: [String: Int] = [:], harmSwaps: [String: Int] = [:], times: [String: [Double]] = [:]
        var athleteTotal = 0, harmTotal = 0
        var changedHarm: [String] = []
        var misses: [String: [String]] = [:]
        for voice in voices where !args.flag("latency-only") {
            let athleteAudio = try athletes.enumerated().map { try speak($1.sentence, voice: voice, name: "a\($0)", in: directory) }
            let harmAudio = try harm.enumerated().map { try speak($1, voice: voice, name: "h\($0)", in: directory) }
            _ = try await engine.transcribe(athleteAudio[0]) as (String, Double)
            for (_, context) in conditions where !context.isEmpty { _ = try await transcribe(engine, athleteAudio[0], context) }
            for (row, audio) in zip(athletes, athleteAudio) {
                athleteTotal += 1
                for (name, context) in conditions {
                    let (text, seconds) = try await transcribe(engine, audio, context)
                    times[name, default: []].append(seconds * 1000)
                    let wanted = [row.name] + (nba.terms.first { $0.surface == row.name }?.aliases ?? [])
                    if wanted.contains(where: { text.contains($0) }) { exact[name, default: 0] += 1 } else {
                        misses[name, default: []].append("[\(voice)] \(row.name): \(text)")
                    }
                }
            }
            for (sentence, audio) in zip(harm, harmAudio) {
                harmTotal += 1
                let (plain, _) = try await transcribe(engine, audio, conditions[0].1)
                for (name, context) in conditions.dropFirst() {
                    let (text, seconds) = try await transcribe(engine, audio, context)
                    times[name, default: []].append(seconds * 1000)
                    if words(text) != words(plain) {
                        harmSwaps[name, default: 0] += 1
                        changedHarm.append("[\(voice) · \(name)] \(sentence)  none: \(plain)  |  \(name): \(text)")
                    }
                }
            }
        }
        print("\n| Condition | Athlete term exact | Harm rows changed | Recogniser ms p50 |")
        print("|---|---:|---:|---:|")
        for (name, _) in conditions {
            let sorted = (times[name] ?? []).sorted()
            let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let harmCell = name == "none" ? "baseline" : "\(harmSwaps[name] ?? 0)/\(harmTotal)"
            print(String(format: "| %@ | %d/%d (%.0f%%) | %@ | %.0f |", name, exact[name] ?? 0, athleteTotal,
                         100 * Double(exact[name] ?? 0) / Double(max(1, athleteTotal)), harmCell, p50))
        }
        // The table's times include rebuilding the boosting session whenever the vocabulary changes between rows. The app
        // keeps one session warm for its standing vocabulary, so time each condition on its own, session already built.
        print("\nRecogniser time with the session already built (\(voices[0]), every athlete and harm sentence):")
        let steady = try (athletes.map(\.sentence) + harm).enumerated().map { try speak($1, voice: voices[0], name: "s\($0)", in: directory) }
        let pack = conditions[1].1
        func capped(_ count: Int) -> VocabularyContext {
            var kept = 0
            return VocabularyContext(terms: pack.terms.filter { term in
                guard term.fromPack else { return true }
                kept += 1
                return kept <= count
            })
        }
        let sweep = conditions + [40, 80, 300].map { ("pack\($0)", $0 == 300 ? vocabulary(nba, fan: false, cap: 300) : capped($0)) }
        for (name, context) in sweep {
            _ = try await transcribe(engine, steady[0], context)
            var spent: [Double] = []
            for audio in steady { spent.append(try await transcribe(engine, audio, context).1 * 1000) }
            spent.sort()
            print(String(format: "  %@ (%d terms): p50 %.0f ms · p95 %.0f ms", name, context.terms.count, spent[spent.count / 2], spent[Int(Double(spent.count) * 0.95)]))
        }
        print("\nHarm rows that changed:")
        for line in changedHarm { print("  \(line)") }
        if changedHarm.isEmpty { print("  none") }
        for (name, _) in conditions {
            print("\nAthlete misses (\(name)):")
            for line in misses[name] ?? [] { print("  \(line)") }
        }
    }

    /// The vocabulary a dictation would get: main's (`PipelineSettings().vocabulary`) plus the lexicon's boost terms.
    static func vocabulary(_ pack: DomainPack, fan: Bool, cap: Int? = nil) -> VocabularyContext {
        var inputs = PersonalLexicon.Inputs()
        inputs.packs = [pack]
        var state = PackState()
        state.setChoice(.on, for: pack)
        inputs.packState = state
        let now = Date()
        if fan {
            inputs.history = athletes.enumerated().map { index, row in
                PersonalLexicon.HistoryText(text: "Talking about \(row.name) again.", date: now.addingTimeInterval(-Double(index % 5) * 86_400))
            }
        }
        var settings = PipelineSettings()
        settings.lexiconTerms = PersonalLexicon.build(inputs, now: now).boostTerms()
        if let cap {
            // Past the shipped cap: the next pack names in pack order, for the latency sweep only.
            let taken = Set(settings.lexiconTerms.map { $0.text.lowercased() })
            let more = pack.terms.filter { PersonalLexicon.isBoostablePackName($0.surface) && !taken.contains($0.surface.lowercased()) }
                .prefix(max(0, cap - settings.lexiconTerms.count))
                .map { VocabularyTerm(text: $0.surface, aliases: $0.aliases, source: .pack) }
            settings.lexiconTerms += more
        }
        return settings.vocabulary
    }

    private static func transcribe(_ engine: Engine, _ audio: [Float], _ context: VocabularyContext) async throws -> (String, Double) {
        try await engine.transcribe(audio, vocabulary: context) as (String, Double)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func speak(_ text: String, voice: String, name: String, in directory: URL) throws -> [Float] {
        let file = directory.appendingPathComponent("\(voice)-\(name).wav")
        try Runners.synthesize(text, voice: voice, to: file)
        return try AudioConverter().resampleAudioFile(path: file.path)
    }
}
