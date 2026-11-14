import Foundation
import Testing
@testable import MurmurCore

/// Routing a spoken request to the file finder: closed frames, a kind table, no
/// phrase-specific exceptions. Positive, negative and near-miss cases.
@Suite("FileRouter")
struct FileRouterTests {
    typealias F = FileFixtures

    @Test("the founder's request becomes a resume query that reveals")
    func founderExample() {
        #expect(F.decide("can you find and fetch my resume") == .file(F.request(["resume"])))
    }

    @Test("file requests become typed queries", arguments: [
        ("find my resume", F.request(["resume"])),
        ("fetch my CV", F.request(["cv"])),
        ("where is my resume", F.request(["resume"])),
        ("where's my resumé", F.request(["resume"])),
        ("hey hushy pull up the invoice from acme", F.request(["invoice", "acme"])),
        ("show me my latest invoice from March", F.request(["invoice"], time: .month(3))),
        ("open my resume pdf", F.request(["resume"], kind: .pdf, action: .open)),
        ("find and open my lease", F.request(["lease"], action: .open)),
        ("pull up the slides about pricing", F.request(["pricing"], kind: .presentation)),
        ("find the doc about pricing", F.request(["pricing"], kind: .document)),
        ("find my sales deck", F.request(["sales"], kind: .presentation)),
        ("get me the spreadsheet in my downloads folder", F.request([], kind: .spreadsheet, location: .downloads)),
        ("find my contract from 2024", F.request(["contract"], time: .year(2024))),
        ("find my tax return from last year", F.request(["tax", "return"], time: .year(2025))),
        ("look for the invoice on my desktop", F.request(["invoice"], location: .desktop)),
        ("show me my screenshots from yesterday", F.request(["screenshot"], kind: .image, time: .recent)),
        ("locate my p d f of the lease", F.request(["lease"], kind: .pdf)),
        ("show me my latest pdf", F.request([], kind: .pdf, time: .recent)),
        ("where did i save my receipt from last month", F.request(["receipt"], time: .monthOfYear(month: 9, year: 2026))),
        ("find my resume.pdf", F.request(["resume"], kind: .pdf)),
        ("find the file called budget", F.request(["budget"])),
        ("open the report", F.request(["report"], action: .open)),
        ("show me the latest report", F.request(["report"], time: .recent)),
        ("i need my passport scan pdf", F.request(["passport", "scan"], kind: .pdf)),
    ])
    func positives(utterance: String, expected: FileRequest) {
        #expect(F.decide(utterance) == .file(expected))
    }

    @Test("ordinary questions and other asks are not file requests", arguments: [
        "what is a resume",
        "how do i write a resume",
        "find a resume template",
        "show me how to make slides",
        "search for resume examples online",
        "find the best invoice software",
        "open slack",
        "find out why the build failed",
        "find a way to fix this",
        "i found my resume yesterday",
        "my resume needs work",
        "remind me to find my resume",
        "write my resume",
        "this pdf is too long",
        "open this pdf",
        "where is the nearest pharmacy",
        "what time is it",
        "tell me about invoices",
    ])
    func negatives(utterance: String) {
        #expect(F.decide(utterance) == .no)
    }

    @Test("a person's own notes, lists and reminders are not files", arguments: [
        "find my notes about pricing",
        "show me my meeting notes",
        "find my note about the vendor contract",
        "find my grocery list",
        "where is my shopping list",
        "pull up my reminders",
        "show me my calendar",
        "find the decision about the contract",
    ])
    func ownStuffIsNotAFile(utterance: String) {
        #expect(F.decide(utterance) == .no)
    }

    @Test("a kind word still makes it a file when notes are mentioned")
    func kindWordBeatsOwnTopic() {
        #expect(F.decide("find my meeting notes pdf") == .file(F.request(["meeting", "notes"], kind: .pdf)))
    }

    @Test("a named folder makes it a file request whatever the noun", arguments: [
        ("find my budget on my desktop", F.request(["budget"], location: .desktop)),
        ("open my thesis draft in my documents folder", F.request(["thesis", "draft"], location: .documents, action: .open)),
        ("show me my wedding plans in downloads", F.request(["wedding", "plans"], location: .downloads)),
        ("where is my quarterly plan on the desktop", F.request(["quarterly", "plan"], location: .desktop)),
        ("pull up my cat pictures in downloads", F.request(["cat"], kind: .image, location: .downloads)),
        ("find my meeting notes in my documents folder", F.request(["meeting", "notes"], location: .documents)),
        ("look for my gym schedule on my desktop", F.request(["gym", "schedule"], location: .desktop)),
        ("find our offsite agenda in documents", F.request(["offsite", "agenda"], location: .documents)),
    ])
    func namedFolder(utterance: String, expected: FileRequest) {
        #expect(F.decide(utterance) == .file(expected))
    }

    @Test("a folder name alone, or a how-to, is not enough", arguments: [
        "find my desktop background", "what is in my downloads", "find a budget template in downloads",
        "show me how to clean my desktop", "find out what is on my desktop",
    ])
    func folderIsNotEnough(utterance: String) {
        if case .file = F.decide(utterance) { Issue.record("\(utterance) became a file request") }
    }

    @Test("find-my-thing with nothing that says file is undecided")
    func undecided() {
        #expect(F.decide("where is my passport") == .undecided)
        #expect(F.decide("find my insurance card") == .undecided)
    }

    // MARK: Through AskRouter

    @Test("AskRouter sends file requests ahead of own-stuff answers")
    func askRouterOrder() {
        #expect(AskRouter.route("find my resume", now: F.now) == .findFile(F.request(["resume"])))
        #expect(AskRouter.route("can you find and fetch my resume", now: F.now) == .findFile(F.request(["resume"])))
    }

    @Test("AskRouter keeps own-notes questions on askOwn")
    func askRouterKeepsOwn() {
        for utterance in ["find my notes about pricing", "show me my meeting notes", "where is my shopping list"] {
            if case .askOwn = AskRouter.route(utterance, now: F.now) { continue }
            Issue.record("\(utterance) did not go to askOwn")
        }
    }

    @Test("AskRouter keeps its other routes")
    func askRouterOtherRoutes() {
        if case .askAI = AskRouter.route("ask claude to find my resume", now: F.now) {} else { Issue.record("ask claude was taken") }
        #expect(AskRouter.route("summarize this pdf", now: F.now) == .summarizeScreen(focus: nil))
        #expect(AskRouter.route("send my resume to dana", now: F.now) == .none)
        #expect(AskRouter.route("what is a resume", now: F.now) == .none)
        #expect(AskRouter.route("find a resume template", now: F.now) == .none)
    }

    @Test("a maybe-file route only where askOwn would have answered")
    func maybeFileOnlyWhereOwnWould() {
        #expect(AskRouter.route("where is my passport", now: F.now) == .maybeFile(question: "where is my passport"))
        #expect(AskRouter.route("get my passport", now: F.now) == .none)
    }

    // MARK: Parts

    @Test("time hints")
    func timeHints() {
        func hint(_ words: String) -> FileTimeHint? {
            var tokens = words.split(separator: " ").map(String.init)
            return FileRouter.takeTime(&tokens, now: F.now, calendar: F.calendar)
        }
        #expect(hint("invoice from march") == .month(3))
        #expect(hint("invoice march 2024") == .monthOfYear(month: 3, year: 2024))
        #expect(hint("invoice in 2023") == .year(2023))
        #expect(hint("invoice last year") == .year(2025))
        #expect(hint("invoice this year") == .year(2026))
        #expect(hint("my latest invoice") == .recent)
        #expect(hint("the march madness bracket") == nil)
        #expect(hint("may i have the invoice") == nil)
    }

    @Test("a model-style path or command is not a valid term")
    func queryRejectsPaths() {
        #expect(FileQuery(terms: ["../../etc/passwd"]) == nil)
        #expect(FileQuery(terms: ["~/Documents"]) == nil)
        #expect(FileQuery(terms: ["resume; rm -rf"]) == nil)
        #expect(FileQuery(terms: ["a", "b", "c", "d", "e", "f", "g"]) == nil)
        #expect(FileQuery(terms: [String(repeating: "x", count: 40)]) == nil)
        #expect(FileQuery(terms: []) == nil)
        #expect(FileQuery(terms: [], kind: .pdf) != nil)
        #expect(FileQuery(terms: ["Resume", "resume"])?.terms == ["resume"])
        #expect(FileQuery.sanitizedTerms(["../../Resume.pdf", "my cv"]) == ["resume", "pdf", "my", "cv"])
    }
}
