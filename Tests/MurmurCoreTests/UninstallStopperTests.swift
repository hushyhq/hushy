import Foundation
import Testing
@testable import MurmurCore

/// Something that never finishes until the test lets it go.
private final class Stuck: Sendable {
    private let stream: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        release = made.continuation
    }

    func wait() async { for await _ in stream {} }
    func letGo() { release.finish() }
}

private actor Ran {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

@Suite("UninstallStopper", .timeLimit(.minutes(1)))
struct UninstallStopperTests {
    private let limit: Duration = .milliseconds(200)

    @Test("every step that stops in time runs, in order")
    func runsEveryStep() async throws {
        let ran = Ran()
        let steps = ["dictation", "the recording", "file imports"].map { name in
            UninstallStopStep(name) { await ran.add(name) }
        }

        try await UninstallStopper.stop(steps, limit: .seconds(30))

        #expect(await ran.names == ["dictation", "the recording", "file imports"])
    }

    @Test("a step that will not stop is named, and the steps after it are not run")
    func namesTheStepThatHangs() async {
        let stuck = Stuck()
        defer { stuck.letGo() }
        let ran = Ran()
        let steps = [
            UninstallStopStep("dictation") { await ran.add("dictation") },
            UninstallStopStep("the recording in progress") { await stuck.wait() },
            UninstallStopStep("file imports") { await ran.add("file imports") },
        ]

        await #expect(throws: UninstallStopFailure(notStopped: "the recording in progress")) {
            try await UninstallStopper.stop(steps, limit: limit)
        }
        #expect(await ran.names == ["dictation"])
    }

    /// Waits for work the stopper left to finish by itself.
    private func wait(until done: () async -> Bool) async {
        for _ in 0..<2_000 {
            if await done() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a recording stop that outlasts its limit and then completes keeps the recording: the uninstall is no longer wanted")
    func aLateStepDiscardsNothing() async {
        let stuck = Stuck()
        let ran = Ran()
        // The shape of a step that ends by discarding: wait first, ask, and only then act.
        let recording = UninstallStopStep("the recording in progress", checking: { isStillWanted in
            await stuck.wait()
            await ran.add(isStillWanted() ? "discarded" : "kept")
        })
        let after = UninstallStopStep("file imports") { await ran.add("file imports") }

        await #expect(throws: UninstallStopFailure(notStopped: "the recording in progress")) {
            try await UninstallStopper.stop([recording, after], limit: limit)
        }
        stuck.letGo()
        await wait { await !ran.names.isEmpty }

        #expect(await ran.names == ["kept"])
    }

    @Test("a step that finishes in time is still wanted, and goes on to discard")
    func aStepInTimeIsStillWanted() async throws {
        let ran = Ran()
        let recording = UninstallStopStep("the recording in progress", checking: { isStillWanted in
            await ran.add(isStillWanted() ? "discarded" : "kept")
        })

        try await UninstallStopper.stop([recording], limit: .seconds(30))

        #expect(await ran.names == ["discarded"])
    }

    @Test("the limit is what was asked for, and the failure names what did not stop and promises nothing more")
    func usesTheLimitItIsGiven() async {
        let stuck = Stuck()
        defer { stuck.letGo() }
        let asked = Ran()

        let finished = await UninstallStopper.finishes({ _ in await stuck.wait() }, within: .seconds(15)) { limit in
            await asked.add("\(limit)")
        }

        #expect(!finished)
        #expect(await asked.names == ["\(Duration.seconds(15))"])
        #expect(UninstallStopper.stepLimit == .seconds(15))
        // What was and was not undone is the sheet's to say (`UninstallSheetContent.abandonedDetail`).
        #expect(UninstallStopFailure(notStopped: "file imports").errorDescription == "Hushy could not stop file imports in time.")
    }

    @Test("work that finishes first wins, and the answer is given once")
    func finishesInTime() async {
        let finished = await UninstallStopper.finishes({ _ in }, within: .seconds(30)) { limit in
            try? await Task.sleep(for: limit)
        }

        #expect(finished)
    }
}
