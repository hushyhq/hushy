import Testing
@testable import MurmurCore

private struct FakeNode: AccessibilityReachNode {
    var characters = 0
    var kids: [FakeNode] = []
    var web = false
    var isWebArea: Bool { web }
    func textCharacterCount() -> Int { characters }
    func childNodes() -> [any AccessibilityReachNode] { kids }
}

/// A clock that advances a fixed step each time it is read.
private final class FakeClock: @unchecked Sendable {
    private var now = 0
    let step: Int
    init(step: Int) { self.step = step }
    func read() -> Int { defer { now += step }; return now }
}

@Suite("AccessibilityReachProbe")
struct AccessibilityReachProbeTests {
    private let tree = FakeNode(characters: 0, kids: [
        FakeNode(characters: 10, kids: [FakeNode(characters: 5), FakeNode(characters: 0)]),
        FakeNode(characters: 20),
        FakeNode(characters: 0, kids: [FakeNode(characters: 7)]),
    ])

    @Test("counts every element, text element and character in a tree that fits the budget")
    func countsWholeTree() {
        let clock = FakeClock(step: 0)
        let counts = AccessibilityReachProbe.walk(root: tree, elapsedMilliseconds: clock.read)
        #expect(counts.elementsVisited == 7)
        #expect(counts.textElements == 4)
        #expect(counts.totalCharacters == 42)
        #expect(counts.stoppedBy == .completed)
        #expect(counts.millisecondsToCharacterTarget == nil)
    }

    @Test("walks breadth first, so the nearest elements are counted before the time runs out")
    func breadthFirst() {
        // Three elements fit in 150 ms at 50 ms a read: the root and its first two children (10 and 20 characters).
        let clock = FakeClock(step: 50)
        let counts = AccessibilityReachProbe.walk(root: tree, budget: .init(milliseconds: 150), elapsedMilliseconds: clock.read)
        #expect(counts.elementsVisited == 3)
        #expect(counts.totalCharacters == 30)
        #expect(counts.stoppedBy == .timeLimit)
    }

    @Test("stops at the element cap")
    func elementCap() {
        let clock = FakeClock(step: 0)
        let counts = AccessibilityReachProbe.walk(root: tree, budget: .init(maxElements: 2), elapsedMilliseconds: clock.read)
        #expect(counts.elementsVisited == 2)
        #expect(counts.stoppedBy == .elementLimit)
    }

    @Test("notes when the running total first reaches the character target")
    func characterTarget() {
        let clock = FakeClock(step: 10)
        let counts = AccessibilityReachProbe.walk(
            root: tree, budget: .init(milliseconds: 1_000, characterTarget: 30), elapsedMilliseconds: clock.read)
        // Root at 0 ms, the first child (10 characters) at 10 ms, the second (20) at 20 ms: 30 reached at 20 ms.
        #expect(counts.millisecondsToCharacterTarget == 20)
    }

    @Test("a negative character count is treated as none")
    func negativeCount() {
        let clock = FakeClock(step: 0)
        let counts = AccessibilityReachProbe.walk(root: FakeNode(characters: -5), elapsedMilliseconds: clock.read)
        #expect(counts.textElements == 0)
        #expect(counts.totalCharacters == 0)
    }

    @Test("an empty tree is one element with no text")
    func singleNode() {
        let clock = FakeClock(step: 0)
        let counts = AccessibilityReachProbe.walk(root: FakeNode(), elapsedMilliseconds: clock.read)
        #expect(counts.elementsVisited == 1)
        #expect(counts.textElements == 0)
    }

    @Test("web content is counted separately: everything at or under a web area")
    func webContent() {
        let tree = FakeNode(characters: 5, kids: [
            FakeNode(characters: 7),
            FakeNode(characters: 0, kids: [FakeNode(characters: 100), FakeNode(characters: 20)], web: true),
        ])
        let clock = FakeClock(step: 0)
        let counts = AccessibilityReachProbe.walk(root: tree, elapsedMilliseconds: clock.read)
        #expect(counts.webAreas == 1)
        #expect(counts.webElements == 3)
        #expect(counts.webCharacters == 120)
        #expect(counts.totalCharacters == 132)
    }

    @Test("the printed line holds counts and times only")
    func lineHasNoText() {
        var counts = AccessibilityReachCounts()
        counts.elementsVisited = 12
        counts.textElements = 3
        counts.totalCharacters = 456
        counts.elapsedMilliseconds = 40
        let line = AccessibilityReachProbe.line("before", counts)
        #expect(line == "before: elements=12 textElements=3 characters=456 webAreas=0 webElements=0 webCharacters=0 time=40 ms 4000CharactersAt=not reached stoppedBy=completed")
    }
}
