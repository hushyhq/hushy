import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// A metadata query that never touches an index: the test decides what it holds and when (or
/// whether) it finishes, and the fake counts what `SpotlightRun` did to it.
@MainActor
private final class FakeQuery: MetadataQueryDriving {
    var files: [FileCandidate]
    var startResult = true
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var disables = 0
    private(set) var handlerSets = 0
    private(set) var handler: (@MainActor () -> Void)?
    private(set) var candidateReads = 0

    init(files: [FileCandidate] = []) { self.files = files }

    func setFinishHandler(_ handler: (@MainActor () -> Void)?) {
        handlerSets += 1
        self.handler = handler
    }
    func start() -> Bool {
        starts += 1
        return startResult
    }
    func disableUpdates() { disables += 1 }
    func stop() { stops += 1 }
    var resultCount: Int { files.count }
    func candidate(at index: Int) -> FileCandidate? {
        candidateReads += 1
        return files[index]
    }

    /// The "gathering finished" notification.
    func finish() { handler?() }
}

@Suite("Spotlight run lifecycle")
@MainActor
struct SpotlightRunLifecycleTests {
    private let home = "/Users/tester"

    private func file(_ relative: String, day: Int = 1) -> FileCandidate {
        FileCandidate(path: home + "/" + relative, modified: Date(timeIntervalSince1970: Double(day) * 86_400), kinds: [.pdf])
    }

    private func spec(limit: Int = 200, box: Duration = .seconds(5), home: String? = nil) -> FileSearchSpec {
        FileSearchSpec(
            pass: .nameAll, termGroups: [["resume"]], kind: .any, roots: [URL(fileURLWithPath: self.home)],
            limit: limit, timeBox: box, homePath: home ?? self.home)
    }

    /// Runs the query and waits until it has started, so the test can then send events to it.
    private func run(_ query: FakeQuery, _ spec: FileSearchSpec) async -> Task<FileSearchResponse, Never> {
        let run = SpotlightRun(driver: query, spec: spec)
        let task = Task { await run.execute() }
        while query.starts == 0 && query.stops == 0 { await Task.yield() }
        return task
    }

    @Test("a finish notification answers with the results, stops the query once and removes the observer")
    func finishNotification() async {
        let query = FakeQuery(files: [file("Documents/Resume.pdf")])
        let task = await run(query, spec())
        query.finish()
        let response = await task.value
        #expect(response == .results([file("Documents/Resume.pdf")]))
        #expect(query.starts == 1)
        #expect(query.stops == 1)
        #expect(query.handler == nil)
        #expect(query.handlerSets == 2)
    }

    @Test("a second finish notification, or a late time box, answers nothing more")
    func finishOnce() async {
        let query = FakeQuery(files: [file("Documents/Resume.pdf")])
        let task = await run(query, spec(box: .milliseconds(150)))
        let stale = query.handler
        query.finish()
        stale?()
        stale?()
        _ = await task.value
        try? await Task.sleep(for: .milliseconds(300))
        #expect(query.stops == 1)
        #expect(query.disables == 1)
    }

    @Test("without a notification the time box answers with what was gathered")
    func timeBox() async {
        let query = FakeQuery(files: [file("Documents/Resume.pdf")])
        let task = await run(query, spec(box: .milliseconds(100)))
        // The fake never sends its notification, so only the time box can produce this answer.
        let response = await task.value
        #expect(response == .results([file("Documents/Resume.pdf")]))
        #expect(query.stops == 1)
        #expect(query.handler == nil)
    }

    @Test("cancelling stops the query, removes the observer and answers once")
    func cancellation() async {
        let query = FakeQuery(files: [file("Documents/Resume.pdf")])
        let task = await run(query, spec())
        task.cancel()
        _ = await task.value
        #expect(query.stops == 1)
        #expect(query.handler == nil)
        query.finish()
        #expect(query.stops == 1)
    }

    @Test("a task cancelled before it starts never starts the query")
    func cancelledBeforeStart() async {
        let query = FakeQuery(files: [file("Documents/Resume.pdf")])
        let run = SpotlightRun(driver: query, spec: spec())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await run.execute()
        }
        _ = await task.value
        #expect(query.starts == 0)
        #expect(query.handler == nil)
    }

    @Test("a query that will not start is a failed search")
    func startFailure() async {
        let query = FakeQuery()
        query.startResult = false
        let response = await SpotlightRun(driver: query, spec: spec()).execute()
        #expect(response == .unavailable(.failed))
        #expect(query.stops == 1)
        #expect(query.handler == nil)
    }

    @Test("out-of-scope hits ahead of a real match do not use up the limit")
    func excludedBeforeLimit() async {
        var files = (1...10).map { file("Library/Caches/c\($0)/Resume.pdf", day: 100 + $0) }
        files += (1...5).map { file("Documents/.git\($0)/Resume.pdf", day: 100) }
        files.append(file("Desktop/Foo.app/Resume.pdf", day: 99))
        let real = file("Documents/Jobs/Resume.pdf", day: 2)
        files.append(real)
        let query = FakeQuery(files: files)
        let task = await run(query, spec(limit: 3))
        query.finish()
        #expect(await task.value == .results([real]))
    }

    @Test("the limit is applied after scope filtering, and the scan stops once it is full")
    func limitAfterScope() async {
        let files = (1...20).map { file("Documents/Report \($0).pdf", day: $0) }
        let query = FakeQuery(files: files)
        let task = await run(query, spec(limit: 4))
        query.finish()
        guard case .results(let list) = await task.value else { Issue.record("no results"); return }
        #expect(list.count == 4)
        #expect(query.candidateReads == 4)
    }

    @Test("with no home path nothing is filtered")
    func noHome() async {
        let query = FakeQuery(files: [file("Library/Resume.pdf")])
        let task = await run(query, spec(home: ""))
        query.finish()
        #expect(await task.value == .results([file("Library/Resume.pdf")]))
    }
}
