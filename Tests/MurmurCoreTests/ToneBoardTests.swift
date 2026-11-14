import Foundation
import Testing

@testable import MurmurCore

private struct BoardApps: InstalledApps {
    let ids: Set<String>
    func isInstalled(_ bundleID: String) -> Bool { ids.contains(bundleID) }
    func displayName(_ bundleID: String) -> String? { ids.contains(bundleID) ? bundleID : nil }
}

/// TRY-93: the tone page organised by tone. Every lane is worked out with the dictation's own `plan` and `register`,
/// and every move is a change to the same `appChoices`, so what the page shows is what dictation does.
@Suite("Tone board: apps by tone")
struct ToneBoardTests {
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let teams = ["com.microsoft.teams2", "com.microsoft.teams"]
    private static let claude = "com.anthropic.claudefordesktop"
    private let mac = BoardApps(ids: [
        slack, "com.microsoft.teams2", "com.apple.mail", "com.apple.MobileSMS", claude, "com.openai.chat",
        "notion.id", "com.apple.Terminal", "com.todesktop.230313mzl4w4u92",
    ])

    private func board(_ settings: ToneSettings = .standard, prompt: Bool = true) -> ToneBoard {
        ToneBoard.make(settings: settings, installed: mac, promptAvailable: prompt)
    }

    private func names(_ lane: ToneLane, _ board: ToneBoard) -> [String] {
        board.lane(lane)?.apps.filter { !$0.isKind }.map(\.name) ?? []
    }

    @Test("a chip moved to Professional makes the dictation's register Professional for that app")
    func movedToProfessional() throws {
        let start = board()
        let slack = try #require(start.app(id: Self.slack))
        #expect(slack.lane == .refined)
        let moved = ToneBoard.moving(slack, to: .professional, in: .standard, promptAvailable: true)
        #expect(moved.register(for: .workMessages, bundleID: Self.slack) == .professional)
        #expect(moved.plan(for: .workMessages, bundleID: Self.slack).tone == .professional)
        // Stored where the dictation already reads it, and nowhere else.
        #expect(moved.appChoices == [Self.slack: .tone(.professional)])
        #expect(moved.appKinds.isEmpty && moved.overrides == ToneSettings.standard.overrides)
        // The board now shows it there, placed by hand; the rest of Work messages is unchanged.
        let after = try #require(board(moved).app(id: Self.slack))
        #expect(after.lane == .professional && after.isPlaced)
        #expect(moved.register(for: .workMessages, bundleID: Self.teams[0]) == nil)
    }

    @Test("a new Mac: Refined holds most apps, Email is Professional, AI apps are Prompt, code takes no tone")
    func startingBoard() {
        let board = board()
        #expect(names(.refined, board) == ["Slack", "Microsoft Teams", "Messages", "Notion"])
        #expect(names(.professional, board) == ["Mail"])
        #expect(names(.casual, board).isEmpty)
        #expect(names(.prompt, board) == ["Claude", "ChatGPT"])
        #expect(Set(board.noTone.map(\.name)) == ["Cursor", "Terminal"])
        #expect(board.lanes.filter(\.isDefault).map(\.lane) == [.refined])
        #expect(board.lanes.allSatisfy { $0.isAvailable })
        #expect(board.lanes.flatMap(\.apps).allSatisfy { !$0.isPlaced })
    }

    @Test("without register lines Prompt is coming: AI apps sit in the tone they really get and cannot be moved there")
    func withoutRegisterLines() throws {
        let board = board(prompt: false)
        let prompt = try #require(board.lane(.prompt))
        #expect(!prompt.isAvailable && prompt.apps.isEmpty)
        #expect(names(.refined, board).contains("Claude") && names(.refined, board).contains("ChatGPT"))
        let slack = try #require(board.app(id: Self.slack))
        #expect(!board.destinations(for: slack).contains(.prompt))
        #expect(ToneBoard.moving(slack, to: .prompt, in: .standard, promptAvailable: false) == .standard)
        // The AI apps follow Everything else, so they move with it.
        let casualElse = ToneSettings.standard.settingTone(.casual, for: .other)
        #expect(names(.casual, self.board(casualElse, prompt: false)).contains("Claude"))
    }

    @Test("moving an app back to where its kind puts it clears its own choice")
    func backToItsKind() throws {
        let moved = ToneBoard.moving(try #require(board().app(id: Self.slack)), to: .casual, in: .standard, promptAvailable: true)
        let slack = try #require(board(moved).app(id: Self.slack))
        #expect(slack.naturalLane == .refined && board(moved).destinations(for: slack).contains(.refined))
        let back = ToneBoard.moving(slack, to: .refined, in: moved, promptAvailable: true)
        #expect(back == .standard)
    }

    @Test("an AI app moved out of Prompt gets that tone's register; moved back, it is a prompt again")
    func aiAppOutOfPrompt() throws {
        let claude = try #require(board().app(id: Self.claude))
        #expect(claude.lane == .prompt && ToneSettings.standard.register(for: .aiPrompts, bundleID: Self.claude) == .prompt)
        let refined = ToneBoard.moving(claude, to: .refined, in: .standard, promptAvailable: true)
        #expect(refined.register(for: .aiPrompts, bundleID: Self.claude) == nil)
        #expect(refined.plan(for: .aiPrompts, bundleID: Self.claude).tone == .refined)
        let back = ToneBoard.moving(try #require(board(refined).app(id: Self.claude)), to: .prompt, in: refined, promptAvailable: true)
        #expect(back == .standard)
    }

    @Test("any writing app can be moved to Prompt: the register is Prompt, the tone pass keeps its kind")
    func notionToPrompt() throws {
        let notion = try #require(board().app(id: "notion.id"))
        let moved = ToneBoard.moving(notion, to: .prompt, in: .standard, promptAvailable: true)
        #expect(moved.appChoices["notion.id"] == .prompt)
        #expect(moved.register(for: .documents, bundleID: "notion.id") == .prompt)
        #expect(moved.plan(for: .documents, bundleID: "notion.id").tone == .refined)
        #expect(names(.prompt, board(moved)).contains("Notion"))
    }

    @Test("an app with two identifiers moves with both")
    func everyIdentifier() throws {
        let teams = try #require(board().app(id: Self.teams[0]))
        let moved = ToneBoard.moving(teams, to: .professional, in: .standard, promptAvailable: true)
        for id in Self.teams { #expect(moved.register(for: .workMessages, bundleID: id) == .professional) }
    }

    @Test("every lane on the board is the lane the dictation's own calls give")
    func boardAgreesWithDictation() {
        let settings = ToneSettings.standard
            .settingTone(.casual, for: .personalMessages)
            .settingApp(.tone(.professional), bundleIDs: [Self.slack])
            .settingApp(.prompt, bundleIDs: ["notion.id"])
            .movingApp(to: .email, bundleIDs: Self.teams)
        for prompt in [true, false] {
            for app in board(settings, prompt: prompt).lanes.flatMap(\.apps) where !app.isKind {
                let category = AppCategory.classify(bundleID: app.id)
                let register = settings.register(for: category, bundleID: app.id)
                let expected: ToneLane = prompt && register == .prompt
                    ? .prompt : ToneLane(tone: settings.plan(for: category, bundleID: app.id).tone ?? .refined)
                #expect(app.lane == expected, "\(app.name), register lines \(prompt)")
            }
        }
    }

    @Test("adding an app puts it in that lane; a browser or a code tool is refused")
    func adding() throws {
        let writer = InstalledAppInfo(bundleID: "com.example.writer", name: "Writer", declaredCategory: nil)
        let added = try #require(ToneBoard.adding(writer, to: .casual, in: .standard, promptAvailable: true))
        #expect(added.addedApps.contains("com.example.writer"))
        #expect(added.plan(for: .other, bundleID: "com.example.writer").tone == .casual)
        let installed = BoardApps(ids: mac.ids.union(["com.example.writer"]))
        #expect(ToneBoard.make(settings: added, installed: installed, promptAvailable: true)
            .lane(.casual)?.apps.map(\.name) == ["com.example.writer"])
        // Added to the lane its kind already gives: listed, with no choice of its own.
        let plain = try #require(ToneBoard.adding(writer, to: .refined, in: .standard, promptAvailable: true))
        #expect(plain.appChoices.isEmpty && plain.addedApps == ["com.example.writer"])
        let safari = InstalledAppInfo(bundleID: "com.apple.Safari", name: "Safari", declaredCategory: nil)
        let zed = InstalledAppInfo(bundleID: "dev.zed.Zed", name: "Zed", declaredCategory: nil)
        let tool = InstalledAppInfo(bundleID: "com.example.zephyr", name: "Zephyr Terminal", declaredCategory: "public.app-category.developer-tools")
        for info in [safari, zed, tool] { #expect(ToneBoard.adding(info, to: .casual, in: .standard, promptAvailable: true) == nil) }
    }

    @Test("As spoken for every app pauses every tone: only As spoken is Default, and the lanes still show where apps go back to")
    func asSpoken() {
        var settings = ToneSettings.standard
        settings.isAsSpoken = true
        let board = board(settings)
        #expect(board.lanes.filter(\.isDefault).map(\.lane) == [.asSpoken])
        #expect(names(.professional, board) == ["Mail"])
    }

    // MARK: Kinds of app on the board

    @Test("each kind of app is one chip in the lane its tone gives: what unplaced apps and websites of that kind get")
    func kindChips() throws {
        let board = board()
        for context in StyleContext.allCases {
            let chip = try #require(board.app(id: ToneBoard.kindChipID(context)))
            #expect(chip.isKind && !chip.isPlaced && chip.name == ToneCopy.kindChipName(context))
            #expect(chip.lane == ToneLane(tone: ToneSettings.standard.tone(for: context)))
            let tail = (board.lane(chip.lane)?.apps ?? []).drop(while: { !$0.isKind }).map(\.isKind)
            #expect(!tail.contains(false), "kinds sit after the apps in their lane")
            // A kind holds a tone, never Prompt or As spoken.
            #expect(!board.destinations(for: chip).contains(.prompt) && !board.destinations(for: chip).contains(.asSpoken))
        }
        #expect(board.app(id: ToneBoard.kindChipID(.email))?.lane == .professional)
    }

    @Test("moving a kind chip sets that kind's tone; moving it back to where it starts clears it")
    func movingKinds() throws {
        let email = try #require(board().app(id: ToneBoard.kindChipID(.email)))
        let casual = ToneBoard.moving(email, to: .casual, in: .standard, promptAvailable: true)
        #expect(casual.tone(for: .email) == .casual && casual.appChoices.isEmpty)
        // Mail follows its kind, so it moves with it; an unplaced Gmail tab gets it too.
        #expect(board(casual).app(id: "com.apple.mail")?.lane == .casual)
        #expect(casual.plan(for: .email, bundleID: "com.google.Chrome").tone == .casual)
        let moved = try #require(board(casual).app(id: ToneBoard.kindChipID(.email)))
        #expect(moved.isPlaced && moved.naturalLane == .professional)
        #expect(ToneBoard.moving(moved, to: .professional, in: casual, promptAvailable: true) == .standard)
        // Moving to a lane that is not a tone changes nothing.
        #expect(ToneBoard.moving(email, to: .asSpoken, in: .standard, promptAvailable: true) == .standard)
        let other = try #require(board().app(id: ToneBoard.kindChipID(.other)))
        let professional = ToneBoard.moving(other, to: .professional, in: .standard, promptAvailable: true)
        #expect(professional.tone(for: .other) == .professional && professional.defaultTone == .refined)
        #expect(ToneBoard.moving(try #require(board(professional).app(id: other.id)), to: .refined, in: professional,
                                 promptAvailable: true) == .standard)
    }


    @Test("each lane's example is the recorded line for this kind of Mac, and only Prompt can have none")
    func examplesByModel() throws {
        for lane in ToneLane.allCases {
            #expect(ToneLaneExample.forLane(lane, registerLines: true) != nil)
        }
        #expect(ToneLaneExample.forLane(.prompt, registerLines: false) == nil)
        #expect(ToneLaneExample.forLane(.refined, registerLines: true) == ToneLaneExample.forLane(.refined, registerLines: false))
        let rewrite = try #require(ToneLaneExample.forLane(.professional, registerLines: true))
        let words = try #require(ToneLaneExample.forLane(.professional, registerLines: false))
        #expect(rewrite.spoken == words.spoken && rewrite.written != words.written)
        #expect(rewrite.written.contains("I don't have the bandwidth for this at this time."))
    }

    @Test("without register lines the examples claim no rewrite: the same words, contractions changed only")
    func wordLevelExamplesClaimNoRewrite() throws {
        // The plain cleanup of the same speech, as Refined would type it; the tone's word pass gives the shown line.
        let plainEmail = "Hi Dana,\n\nThanks for thinking of me for the panel, but I'm going to have to say no this time. I don't have the bandwidth for this right now."
        #expect(ToneRegister.apply(.professional, to: plainEmail, in: .email) == ToneLaneExample.professionalWords.written)
        let plainMessage = "Hey, I'm running like 10 minutes late. Grab us a table and I'll be there."
        #expect(ToneRegister.apply(.casual, to: plainMessage, in: .personalMessages) == ToneLaneExample.casualWords.written)
        for (tone, line) in [(DictationTone.professional, ToneLaneExample.professionalWords), (.casual, .casualWords)] {
            let plain = tone == .professional ? plainEmail : plainMessage
            let introduced = ToneRegister.introducedWords(from: plain, to: line.written)
            #expect(Set(introduced.keys).isSubset(of: ToneRegister.closedIntroductions(for: tone)), "\(tone): \(introduced)")
        }
    }

    @Test("every spoken line reads as speech recognition hands it over, and As spoken types it unchanged")
    func spokenLines() {
        let lines = ToneLane.allCases.flatMap { lane in
            [true, false].compactMap { ToneLaneExample.forLane(lane, registerLines: $0) }
        }
        for line in lines {
            #expect(line.spoken == line.spoken.lowercased(), "\(line.spoken)")
            #expect(!line.spoken.contains(where: { ".,?!".contains($0) }), "\(line.spoken)")
        }
        let verbatim = TextCleaner(options: CleanupOptions(level: .verbatim)).clean(ToneLaneExample.asSpoken.spoken).text
        #expect(verbatim == ToneLaneExample.asSpoken.written)
    }

    @Test("lane copy says rewording only where the model rewords")
    func laneCopy() {
        for lane in [ToneLane.professional, .casual] {
            #expect(ToneCopy.laneDetail(lane, registerLines: false) == lane.tone?.detail)
            #expect(ToneCopy.laneDetail(lane, registerLines: true) != lane.tone?.detail)
        }
        #expect(ToneCopy.promptComing(.standard).hasSuffix("AI apps use Refined."))
    }
}
