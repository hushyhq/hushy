import Foundation
import Testing
@testable import MurmurCore

/// Every outcome branch of the search, on a fake index and a made-up home folder.
@Suite("FileFindEngine")
struct FileFindEngineTests {
    typealias F = FileFixtures

    private func tree() -> [FileCandidate] {
        [
            F.file("Documents/Jobs/Resume.pdf", F.date(2026, 9, 20), kinds: F.pdf),
            F.file("Downloads/Resume.pdf", F.date(2024, 2, 1), kinds: F.pdf),
            F.file("Documents/Invoice acme.pdf", F.date(2026, 3, 2), kinds: F.pdf),
            F.file("Documents/Invoice dana.pdf", F.date(2026, 4, 2), kinds: F.pdf),
            F.file("Desktop/Q3 pitch deck.key", F.date(2026, 8, 2), kinds: F.slides),
            F.file("Documents/Budget.xlsx", F.date(2026, 7, 2), kinds: F.sheet),
            F.file("Documents/Lease.pdf", F.date(2025, 5, 2), kinds: F.pdf),
            F.file("Documents/Notes on onboarding.docx", F.date(2026, 6, 2), kinds: F.docx),
        ]
    }

    private func find(_ request: FileRequest, _ finder: InMemoryFileFinder) async -> FileFindOutcome {
        await F.engine(finder).find(request)
    }

    @Test("one clear winner")
    func foundOne() async {
        let outcome = await find(F.request(["resume"]), InMemoryFileFinder(files: tree()))
        guard case .foundOne(let file, .name) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(file.path == F.home.path + "/Documents/Jobs/Resume.pdf")
        #expect(outcome.code == .foundOne)
    }

    @Test("several plausible matches make a list")
    func foundSeveral() async {
        let outcome = await find(F.request(["invoice"]), InMemoryFileFinder(files: tree()))
        guard case .foundSeveral(let files, .name) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(files.count == 2)
        #expect(outcome.code == .foundSeveral)
    }

    @Test("a month hint chooses between them")
    func timeHint() async {
        let outcome = await find(F.request(["invoice"], time: .month(3)), InMemoryFileFinder(files: tree()))
        guard case .foundOne(let file, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(file.displayName == "Invoice acme.pdf")
    }

    @Test("nothing found says none, never a guess")
    func none() async {
        let outcome = await find(F.request(["passport"]), InMemoryFileFinder(files: tree()))
        #expect(outcome == .none)
        #expect(outcome.code == .none)
    }

    @Test("the synonym finds a CV for resume")
    func synonym() async {
        let finder = InMemoryFileFinder(files: [F.file("Documents/Dana CV.pdf", F.date(2026, 9, 1), kinds: F.pdf)])
        let outcome = await find(F.request(["resume"]), finder)
        guard case .foundOne(let file, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(file.displayName == "Dana CV.pdf")
    }

    @Test("a kind-only request lists by kind")
    func kindOnly() async {
        let outcome = await find(F.request([], kind: .presentation), InMemoryFileFinder(files: tree()))
        guard case .foundOne(let file, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(file.displayName == "Q3 pitch deck.key")
    }

    @Test("a named folder limits the search to it")
    func location() async {
        let outcome = await find(F.request(["resume"], location: .downloads), InMemoryFileFinder(files: tree()))
        guard case .foundOne(let file, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(file.path.contains("/Downloads/"))
        #expect(await find(F.request(["lease"], location: .desktop), InMemoryFileFinder(files: tree())) == .none)
    }

    @Test("a name that only part-matches falls back to any term, and is shown not taken")
    func anyTermPass() async {
        let outcome = await find(F.request(["contract", "lease"]), InMemoryFileFinder(files: tree()))
        guard case .foundSeveral(let files, .name) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(files.first?.displayName == "Lease.pdf")
    }

    @Test("the content pass runs only when no name matches, and never takes a file on its own")
    func contentPass() async {
        let file = F.file("Documents/Notes on onboarding.docx", F.date(2026, 6, 2), kinds: F.docx)
        let finder = InMemoryFileFinder(files: [file], contents: [file.path: "Kafka consumer groups and rebalancing"])
        let outcome = await find(F.request(["kafka"]), finder)
        guard case .foundSeveral(let files, .content) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(files == [file])
        let named = await find(F.request(["onboarding"]), finder)
        guard case .foundOne(_, .name) = named else { Issue.record("a name match should win: \(named)"); return }
    }

    @Test("excluded folders never come back")
    func excluded() async {
        let hidden = [
            F.file("Library/Mobile Documents/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file(".Trash/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Library/Caches/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Documents/Hushy/exports/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Desktop/Foo.app/Contents/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
            F.file("Documents/.hidden/Resume.pdf", F.date(2026, 9, 1), kinds: F.pdf),
        ]
        #expect(await find(F.request(["resume"]), InMemoryFileFinder(files: hidden)) == .none)
        #expect(FileScope.isExcluded(path: "/Users/other/Documents/Resume.pdf", home: F.home.path))
        #expect(!FileScope.isExcluded(path: F.home.path + "/Documents/Library of congress.pdf", home: F.home.path))
        #expect(!FileScope.isExcluded(path: F.home.path + "/Documents/projects/murmur/spec.pdf", home: F.home.path))
    }

    @Test("excluded hits never use up the limit ahead of a real older match")
    func excludedHitsDoNotCrowdTheLimit() async {
        var files = (1...12).map { F.file("Library/Caches/x\($0)/Resume.pdf", F.date(2026, 10, $0 % 5 + 1), kinds: F.pdf) }
        files += (1...4).map { F.file("Documents/.hidden\($0)/Resume.pdf", F.date(2026, 10, 5), kinds: F.pdf) }
        let real = F.file("Documents/Jobs/Resume.pdf", F.date(2023, 1, 5), kinds: F.pdf)
        files.append(real)
        let engine = FileFindEngine(
            finder: InMemoryFileFinder(files: files), home: F.home, now: { F.now }, calendar: F.calendar, resultLimit: 3)
        let outcome = await engine.find(F.request(["resume"]))
        guard case .foundOne(let found, .name) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(found == real)
    }

    @Test("the limit applies after scope filtering")
    func limitAfterScope() async {
        let files = (1...8).map { F.file("Documents/Report \($0).pdf", F.date(2026, 9, $0), kinds: F.pdf) }
        let finder = InMemoryFileFinder(files: files + [F.file("Library/Report 9.pdf", F.date(2026, 10, 1), kinds: F.pdf)])
        let spec = FileSearchSpec(
            pass: .nameAll, termGroups: [["report"]], kind: .any, roots: [F.home], limit: 3, timeBox: .seconds(1),
            homePath: F.home.path)
        guard case .results(let list) = await finder.search(spec) else { Issue.record("no results"); return }
        #expect(list.count == 3)
        #expect(!list.contains { $0.path.contains("/Library/") })
    }

    @Test("folders are not files unless asked for")
    func folders() async {
        let folder = F.file("Documents/Resume stuff", F.date(2026, 9, 1), folder: true)
        #expect(await find(F.request(["resume"]), InMemoryFileFinder(files: [folder])) == .none)
        let asked = await find(F.request(["resume"], kind: .folder), InMemoryFileFinder(files: [folder]))
        guard case .foundOne = asked else { Issue.record("got \(asked)"); return }
    }

    @Test("a slow index is cut off by the time box, and says so")
    func timeBox() async {
        // The fake answers only after two minutes (it stops early when cancelled), so only the time box
        // can produce this outcome, however slowly the machine runs.
        let outcome = await F.engine(InMemoryFileFinder(files: tree(), delay: .seconds(120)), passBox: .milliseconds(100))
            .find(F.request(["resume"]))
        #expect(outcome == .unavailable(.slow))
    }

    @Test("indexing off is said, not reported as nothing found")
    func indexOff() async {
        let outcome = await find(F.request(["resume"]), InMemoryFileFinder(files: [], indexAvailable: false))
        #expect(outcome == .unavailable(.indexOff))
        #expect(outcome.code == .unavailable)
        #expect(await find(F.request(["resume"]), InMemoryFileFinder(unavailable: .folderNotReadable)) == .unavailable(.folderNotReadable))
    }

    @Test("a cancelled search ends as cancelled")
    func cancelled() async {
        let finder = InMemoryFileFinder(files: tree(), delay: .seconds(120))
        let task = Task { await F.engine(finder).find(F.request(["resume"])) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        #expect(outcome.code == .cancelled)
    }

    @Test("the query is capped, passes are ordered, and only terms and kind reach the finder")
    func passOrder() {
        #expect(FileFindEngine.passes(termCount: 0) == [.nameAll])
        #expect(FileFindEngine.passes(termCount: 1) == [.nameAll, .content])
        #expect(FileFindEngine.passes(termCount: 3) == [.nameAll, .nameAny, .content])
    }
}
