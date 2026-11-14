import Foundation
import Testing
@testable import MurmurCore

/// The personal lexicon: decay, pack activation, ranking and the boost list. Every sentence is invented.
@Suite("Personal lexicon")
struct PersonalLexiconTests {
    private static let day: TimeInterval = 24 * 3600
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    private static let pack = DomainPack(
        id: "test.hoops", version: "1", title: "Test", licence: "CC0-1.0", sourceURL: "https://example.org",
        sourceNote: "invented", terms: [
            .init(surface: "Stephen Curry", aliases: [], kind: .person),
            .init(surface: "Luka Dončić", aliases: ["Luka Doncic"], kind: .person),
            .init(surface: "Victor Wembanyama", aliases: [], kind: .person),
            .init(surface: "Jalen Green", aliases: [], kind: .person),
            .init(surface: "Giannis Antetokounmpo", aliases: [], kind: .person),
            .init(surface: "Golden State Warriors", aliases: [], kind: .org),
        ])

    private func build(history: [(String, Double)] = [], learned: [LearnedItem] = [], attendees: [(String, Double)] = [],
                       state: PackState = PackState()) -> LexiconSnapshot {
        var inputs = PersonalLexicon.Inputs()
        inputs.history = history.map { .init(text: $0.0, date: Self.ago($0.1)) }
        inputs.learned = learned
        inputs.attendees = attendees.map { .init(name: $0.0, date: Self.ago($0.1)) }
        inputs.packState = state
        inputs.packs = [Self.pack]
        return PersonalLexicon.build(inputs, now: Self.now, calendar: Self.utc)
    }

    // MARK: Decay

    @Test("a use halves every 30 days and a confirmation does not fade")
    func decay() {
        var term = PersonalTerm(surface: "Siobhan Kearney", kind: .person, sources: [.calendar], uses: 1,
                                firstSeen: Self.ago(30), lastSeen: Self.ago(30))
        #expect(abs(term.decayedUses(at: Self.now) - 0.5) < 1e-9)
        term.use(at: Self.now)
        #expect(abs(term.uses - 1.5) < 1e-9)
        let taught = PersonalTerm(surface: "Siobhan", kind: .person, sources: [.edit], confirmations: 1,
                                  firstSeen: Self.ago(400), lastSeen: Self.ago(400))
        #expect(taught.score(at: Self.now) >= PersonalLexicon.confirmationWeight)
    }

    @Test("an unused name falls out of the boost list but stays in the lexicon")
    func unusedNameDecaysOut() {
        let recent = build(attendees: [("Siobhan Kearney", 2)])
        #expect(recent.boostTerms().map(\.text) == ["Siobhan Kearney"])
        let old = build(attendees: [("Siobhan Kearney", 200)])
        #expect(old.boostTerms().isEmpty)
        #expect(old.terms.map(\.surface) == ["Siobhan Kearney"])
    }

    @Test("a name only Hushy's own output shows needs two recent kept dictations")
    func historyOnlyThreshold() {
        let once = build(history: [("Then I talked to Anouk Vermeulen about it.", 1)])
        #expect(once.boostTerms().isEmpty)
        let twice = build(history: [("Then I talked to Anouk Vermeulen about it.", 1), ("Lunch with Anouk Vermeulen moved.", 3)])
        #expect(twice.boostTerms().map(\.text) == ["Anouk Vermeulen"])
        let longAgo = build(history: [("Then I talked to Anouk Vermeulen.", 90), ("Lunch with Anouk Vermeulen moved.", 95)])
        #expect(longAgo.boostTerms().isEmpty)
    }

    // MARK: Shape: never an ordinary word

    @Test("ordinary words and UI labels never boost, names and identifiers do")
    func shape() {
        for word in ["text", "Next", "the", "Meeting", "Done", "voice", "privacy"] {
            #expect(!LexiconTermShape.isBoostable(word), "\(word)")
        }
        for term in ["Wembanyama", "Victor Wembanyama", "useEffect", "rl-v9", "TRY-95", "snake_case", "tryhushy.com", "kubectl"] {
            #expect(LexiconTermShape.isBoostable(term), "\(term)")
        }
        // "next" on screen or in History never becomes a boost.
        let snapshot = build(history: [("Click Next and then Text me the Done list.", 1), ("Press Next again.", 2)])
        #expect(snapshot.boostTerms().isEmpty)
    }

    // MARK: Pack activation

    @Test("a pack switches on after several distinct names on more than one day, not before")
    func activation() {
        var evidence = PackEvidence()
        evidence.record([0, 1, 2], on: PackEvidence.dayKey(Self.ago(1), calendar: Self.utc))
        let oneDay = PackActivation.evaluate(packID: "p", evidence: evidence, choice: .automatic, now: Self.now, calendar: Self.utc)
        #expect(!oneDay.active && oneDay.evidenceHits == 3 && oneDay.distinctDays == 1)
        evidence.record([2], on: PackEvidence.dayKey(Self.ago(3), calendar: Self.utc))
        let twoDays = PackActivation.evaluate(packID: "p", evidence: evidence, choice: .automatic, now: Self.now, calendar: Self.utc)
        #expect(twoDays.active && twoDays.distinctDays == 2)

        var sameName = PackEvidence()
        for daysAgo in 1...5 { sameName.record([0], on: PackEvidence.dayKey(Self.ago(Double(daysAgo)), calendar: Self.utc)) }
        #expect(!PackActivation.evaluate(packID: "p", evidence: sameName, choice: .automatic, now: Self.now, calendar: Self.utc).active)
    }

    @Test("evidence outside the window does not count; the person's choice wins over evidence")
    func windowAndChoice() {
        var old = PackEvidence()
        old.record([0, 1], on: PackEvidence.dayKey(Self.ago(100), calendar: Self.utc))
        old.record([2, 3], on: PackEvidence.dayKey(Self.ago(101), calendar: Self.utc))
        #expect(!PackActivation.evaluate(packID: "p", evidence: old, choice: .automatic, now: Self.now, calendar: Self.utc).active)
        #expect(PackActivation.evaluate(packID: "p", evidence: old, choice: .on, now: Self.now, calendar: Self.utc).active)
        var fresh = PackEvidence()
        fresh.record([0, 1], on: PackEvidence.dayKey(Self.ago(1), calendar: Self.utc))
        fresh.record([2], on: PackEvidence.dayKey(Self.ago(2), calendar: Self.utc))
        #expect(!PackActivation.evaluate(packID: "p", evidence: fresh, choice: .off, now: Self.now, calendar: Self.utc).active)
    }

    @Test("History about basketball switches the pack on and boosts its names, the fan's own players first")
    func historyActivatesPack() {
        let snapshot = build(history: [
            ("Did you see Wembanyama block that shot last night?", 1),
            ("Doncic and Stephen Curry both scored forty.", 2),
        ])
        #expect(snapshot.activations.first?.active == true)
        let boost = snapshot.boostTerms().map(\.text)
        #expect(boost.contains("Victor Wembanyama"))
        let packPart = boost.filter { name in Self.pack.terms.contains { $0.surface == name } }
        #expect(Array(packPart.prefix(2)).sorted() == ["Luka Dončić", "Victor Wembanyama"])
        // Names whose last word is ordinary English never boost: "Stephen Curry" was seen, "Jalen Green" and
        // "Golden State Warriors" were not, and none of them is in the list.
        #expect(packPart == ["Luka Dončić", "Victor Wembanyama", "Giannis Antetokounmpo"])
        #expect(!boost.contains("Wembanyama"))
        #expect(!boost.contains("Green"))
    }

    @Test("no evidence: no pack, no boost terms")
    func noEvidenceNoChange() {
        let snapshot = build(history: [("Let's meet at noon to go over the plan.", 1), ("Send me the notes.", 2)])
        #expect(snapshot.boostTerms().isEmpty)
        #expect(snapshot.activations.allSatisfy { !$0.active })
        #expect(LexiconSnapshot.empty.boostTerms().isEmpty)
    }

    @Test("a surname that is an English word is not evidence; a distinctive one is")
    func matcherSurnames() {
        let matcher = PackMatcher(pack: Self.pack)
        #expect(matcher.hits(in: "The lawn is so green this year") == [])
        #expect(matcher.hits(in: "wembanyama again!") == [2])
        #expect(matcher.hits(in: "LUKA DONCIC and Luka Dončić") == [1])
        #expect(matcher.hits(in: "Antetokounmpos") == [])
    }

    @Test("switching a pack off clears its screen evidence and keeps no new evidence")
    func offClearsEvidence() {
        var state = PackState()
        state.recordScreen([0, 1, 2], for: Self.pack, at: Self.ago(1), calendar: Self.utc)
        #expect(!state.screenEvidence(for: Self.pack).isEmpty)
        state.setChoice(.off, for: Self.pack)
        #expect(state.screenEvidence(for: Self.pack).isEmpty)
        state.recordScreen([3], for: Self.pack, at: Self.now, calendar: Self.utc)
        #expect(state.screenEvidence(for: Self.pack).isEmpty)
        state.eraseAll()
        #expect(state.choice(for: Self.pack.id) == .automatic)
    }

    @Test("screen evidence for an older pack version is dropped")
    func packVersionChange() {
        var state = PackState()
        state.recordScreen([0, 1, 2], for: Self.pack, at: Self.ago(1), calendar: Self.utc)
        var newer = Self.pack
        newer.version = "2"
        #expect(state.screenEvidence(for: newer).isEmpty)
    }

    @Test("the state file round-trips and erases")
    func stateFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-\(UUID().uuidString).json")
        let file = PackStateFile(url: url)
        defer { try? file.erase() }
        var state = PackState()
        state.recordScreen([1, 4], for: Self.pack, at: Self.now, calendar: Self.utc)
        state.setChoice(.on, for: Self.pack)
        try file.save(state)
        #expect(file.load() == state)
        try file.erase()
        #expect(file.load() == PackState())
    }

    // MARK: Ranking

    @Test("ranking: taught terms first, then by decayed uses, then newest, then spelling")
    func ranking() {
        let taught = LearnedItem(kind: .term, key: "kubernetes", value: "Kubernetes", status: .active,
                                 createdAt: Self.ago(300), lastSeenAt: Self.ago(300))
        let snapshot = build(
            history: [
                ("Ping Anouk Vermeulen today.", 1), ("Ask Anouk Vermeulen.", 2), ("Ask Anouk Vermeulen again.", 3),
                ("Ping Bram Oosterhuis.", 1), ("Ask Bram Oosterhuis.", 2),
            ],
            learned: [taught], attendees: [("Zofia Wiśniewska", 1)])
        #expect(snapshot.terms.map(\.surface) == ["Kubernetes", "Anouk Vermeulen", "Bram Oosterhuis", "Zofia Wiśniewska"])
        // The Dictionary already carries an active learned term: the lexicon leaves it to that path.
        #expect(snapshot.boostTerms(excluding: ["kubernetes"]).map(\.text) == ["Anouk Vermeulen", "Bram Oosterhuis", "Zofia Wiśniewska"])
    }

    @Test("forgotten or kept-as-heard blocks a term from every source, packs included")
    func blocked() {
        let forgotten = LearnedItem(kind: .term, key: "victor wembanyama", value: "Victor Wembanyama", status: .forgotten)
        let snapshot = build(history: [
            ("Wembanyama again.", 1), ("Doncic and Stephen Curry.", 2),
        ], learned: [forgotten])
        #expect(snapshot.activations.first?.active == true)
        #expect(!snapshot.boostTerms().map(\.text).contains("Victor Wembanyama"))
    }

    @Test("the boost list keeps to its caps")
    func caps() {
        let manyNames = (0..<80).map { index -> (String, Double) in ("Met Zorbix\(index)name today.", 1) }
        let snapshot = build(history: manyNames + manyNames.map { ($0.0, 2) })
        #expect(snapshot.boostTerms().count == PersonalLexicon.maxPersonalBoostTerms)
    }

    @Test("a pack name whose last word is ordinary English is not boosted")
    func ordinarySurnames() {
        for name in ["Kevin Love", "Jalen Green", "Stephen Curry", "Miami Heat", "Utah Jazz", "Golden State Warriors"] {
            #expect(!PersonalLexicon.isBoostablePackName(name), "\(name)")
        }
        for name in ["Victor Wembanyama", "Shai Gilgeous-Alexander", "Luka Dončić", "Jaren Jackson Jr.", "Kristaps Porziņģis"] {
            #expect(PersonalLexicon.isBoostablePackName(name), "\(name)")
        }
    }

    @Test("the boost keeps a pack name the recogniser wrote and keeps fixing names it misheard")
    func packNameGuard() {
        let matchers = [PackMatcher(pack: Self.namesakes)]
        #expect(PackNameGuard.keepHeardNames(original: "Anthony Edwards dunked over two defenders.",
                                             boosted: "Anthony Davis dunked over two defenders.", matchers: matchers)
                == "Anthony Edwards dunked over two defenders.")
        #expect(PackNameGuard.keepHeardNames(original: "Amen Thompson guards all five positions.",
                                             boosted: "Klay Thompson guards all five positions.", matchers: matchers)
                == "Amen Thompson guards all five positions.")
        #expect(PackNameGuard.keepHeardNames(original: "Victor Wembanaima blocked six shots.",
                                             boosted: "Victor Wembanyama blocked six shots.", matchers: matchers)
                == "Victor Wembanyama blocked six shots.")
        // A fix elsewhere in the same sentence survives the revert of the swapped name.
        #expect(PackNameGuard.keepHeardNames(original: "Anthony Edwards and Victor Wembanaima.",
                                             boosted: "Anthony Davis and Victor Wembanyama.", matchers: matchers)
                == "Anthony Edwards and Victor Wembanyama.")
    }

    private static let namesakes = DomainPack(
        id: "test.namesakes", version: "1", title: "Test", licence: "CC0-1.0", sourceURL: "https://example.org",
        sourceNote: "invented", terms: [
            .init(surface: "Anthony Davis", aliases: [], kind: .person),
            .init(surface: "Anthony Edwards", aliases: [], kind: .person),
            .init(surface: "Klay Thompson", aliases: [], kind: .person),
            .init(surface: "Amen Thompson", aliases: [], kind: .person),
            .init(surface: "Victor Wembanyama", aliases: [], kind: .person),
        ])

    // MARK: The bundled packs

    @Test("every bundled pack decodes, says its licence and source, and matches its JSON file")
    func bundledPacks() throws {
        let packs = DomainPackCatalog.all
        #expect(packs.map(\.id).sorted() == ["medicine.drugs", "sports.nba", "tech.tools"])
        for pack in packs {
            #expect(!pack.licence.isEmpty && pack.sourceURL.hasPrefix("https://") && !pack.sourceNote.isEmpty)
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/MurmurCore/Lexicon/Packs").standardizedFileURL
        for file in DomainPackData.files {
            let onDisk = try String(contentsOf: folder.appendingPathComponent(file.name), encoding: .utf8)
            #expect(onDisk.trimmingCharacters(in: .newlines) == file.json, "\(file.name): rerun scripts/lexicon/embed_packs.py")
        }
        let nba = try #require(DomainPackCatalog.pack(id: "sports.nba"))
        #expect(nba.licence == "CC0-1.0" && nba.terms.count > 1_000)
        let rank = try #require(nba.terms.firstIndex { $0.surface == "Victor Wembanyama" })
        #expect(rank < PersonalLexicon.maxPackBoostTerms)
    }

    // MARK: Store

    @Test("the store hands over kept English dictations only")
    func storeInputs() throws {
        let store = try Store()
        _ = try store.save(Dictation(createdAt: Self.ago(1), rawText: "a", text: "Kept with Anouk Vermeulen.", durationSeconds: 1))
        var edited = Dictation(createdAt: Self.ago(1), rawText: "b", text: "Edited with Bram Oosterhuis.", durationSeconds: 1)
        edited.editState = .edited
        _ = try store.save(edited)
        _ = try store.save(Dictation(createdAt: Self.ago(1), rawText: "c", text: "Avec Zofia.", durationSeconds: 1, language: "fr"))
        _ = try store.save(Dictation(createdAt: Self.ago(1), rawText: "d", text: "Cancelled Lotte.", durationSeconds: 1, status: .cancelled))
        let inputs = try store.lexiconInputs()
        #expect(inputs.history.map(\.text) == ["Kept with Anouk Vermeulen."])
    }

    // MARK: Pipeline

    @Test("lexicon terms join the vocabulary after the Dictionary and screen, and nothing changes without them")
    func pipelineVocabulary() {
        let plain = PipelineSettings(contextTerms: ["Zorbix"])
        var withLexicon = plain
        withLexicon.lexiconTerms = [VocabularyTerm(text: "Victor Wembanyama"), VocabularyTerm(text: "zorbix")]
        #expect(plain.vocabulary == PipelineSettings(contextTerms: ["Zorbix"]).vocabulary)
        let texts = withLexicon.vocabulary.terms.map(\.text)
        #expect(Array(texts.prefix(2)) == ["Zorbix", "Victor Wembanyama"])
        #expect(!texts.contains("zorbix"))
        #expect(PipelineSettings().contextWarmVocabulary == nil)
        #expect(withLexicon.contextWarmVocabulary != nil)
    }
}
