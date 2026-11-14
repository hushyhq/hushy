import Foundation
import Testing
@testable import MurmurCore

@Suite("FileRanker")
struct FileRankerTests {
    typealias F = FileFixtures

    private func rank(_ files: [FileCandidate], _ request: FileRequest) -> [RankedFile] {
        FileRanker.rank(files, for: request.query, now: F.now, home: F.home.path, calendar: F.calendar)
    }

    @Test("an exact name beats a longer one")
    func exactNameFirst() {
        let ranked = rank([
            F.file("Documents/Resume of the board meeting 2019.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Documents/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
        ], F.request(["resume"]))
        #expect(ranked.first?.candidate.displayName == "Resume.pdf")
    }

    @Test("a clearly newer file wins; two close ones make a list")
    func recencyMargin() {
        let recent = F.file("Documents/Resume.pdf", F.date(2026, 9, 20), kinds: F.pdf)
        let old = F.file("Downloads/Resume.pdf", F.date(2024, 2, 1), kinds: F.pdf)
        let close = F.file("Downloads/Resume.pdf", F.date(2026, 9, 10), kinds: F.pdf)
        let request = F.request(["resume"])
        if case .one(let winner) = FileRanker.decide(rank([recent, old], request)) {
            #expect(winner.candidate.path.hasSuffix("Documents/Resume.pdf"))
        } else {
            Issue.record("a file two years older should lose clearly")
        }
        if case .several(let list) = FileRanker.decide(rank([recent, close], request)) {
            #expect(list.count == 2)
        } else {
            Issue.record("two resumes ten days apart should be a list")
        }
    }

    @Test("last-used counts as recent")
    func lastUsed() {
        let used = F.file("Documents/Resume.pdf", F.date(2023, 1, 1), kinds: F.pdf, lastUsed: F.date(2026, 10, 1))
        #expect(used.recency == F.date(2026, 10, 1))
    }

    @Test("a shallower path breaks a tie")
    func shallowerPath() {
        let ranked = rank([
            F.file("Documents/a/b/c/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Documents/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
        ], F.request(["resume"]))
        #expect(ranked.first?.candidate.path == F.home.path + "/Documents/Resume.pdf")
    }

    @Test("a single file that matches only part of the name is shown, not taken")
    func partialCoverageNeverWins() {
        let ranked = rank([F.file("Documents/Contract.pdf", F.date(2026, 9, 1), kinds: F.pdf)], F.request(["contract", "dana"]))
        if case .several(let list) = FileRanker.decide(ranked) { #expect(list.count == 1) } else { Issue.record("partial match was taken") }
    }

    @Test("a month hint that no file matches is never taken as the winner")
    func timeHintMismatch() {
        let ranked = rank([F.file("Documents/Invoice.pdf", F.date(2026, 4, 2), kinds: F.pdf)], F.request(["invoice"], time: .month(3)))
        if case .several = FileRanker.decide(ranked) {} else { Issue.record("an April invoice was taken for March") }
    }

    @Test("a month hint that one file matches picks it")
    func timeHintMatch() {
        let ranked = rank([
            F.file("Documents/Invoice acme.pdf", F.date(2026, 3, 2), kinds: F.pdf),
            F.file("Documents/Invoice dana.pdf", F.date(2026, 4, 2), kinds: F.pdf),
        ], F.request(["invoice"], time: .month(3)))
        if case .one(let winner) = FileRanker.decide(ranked) { #expect(winner.candidate.displayName == "Invoice acme.pdf") } else { Issue.record("March invoice not picked") }
    }

    @Test("the list never shows more than five")
    func listCap() {
        let files = (1...9).map { F.file("Documents/Report \($0).pdf", F.date(2026, 9, $0), kinds: F.pdf) }
        if case .several(let list) = FileRanker.decide(rank(files, F.request(["report"]))) { #expect(list.count == 5) } else { Issue.record("expected a list") }
    }

    @Test("no candidates is none")
    func empty() {
        #expect(FileRanker.decide([]) == .none)
    }
}
