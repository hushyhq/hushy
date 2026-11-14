import Testing
@testable import MurmurCore

/// Which sentence groups may be cleaned while the person is still speaking (`EarlyCleanupQueue`): only closed groups, never
/// the last one, each handed out once, and nothing after the key release.
@Suite("Early cleanup: which groups are cleaned while speaking")
struct EarlyCleanupQueueTests {
    /// Ten words each, so two make one group and a third would overflow it.
    private let sentences = (1...8).map { "The report for region number \($0) is ready for review." }

    private func transcript(_ count: Int, extra: String = "") -> String {
        (Array(sentences.prefix(count)) + (extra.isEmpty ? [] : [extra])).joined(separator: " ")
    }

    private func drain(_ queue: inout EarlyCleanupQueue) -> [String] {
        var out: [String] = []
        while let next = queue.next() { out.append(next) }
        return out
    }

    @Test("text short enough for one model call offers nothing")
    func shortTextOffersNothing() {
        var queue = EarlyCleanupQueue()
        queue.heard(transcript(3))
        #expect(TextSegmentation.groups(transcript(3)).count == 1)
        #expect(queue.next() == nil)
        #expect(queue.started.isEmpty)
    }

    @Test("every closed group is handed out in order, and the last group never is")
    func closedGroupsInOrderNeverTheLast() {
        var queue = EarlyCleanupQueue()
        let text = transcript(6)
        let groups = TextSegmentation.groups(text)
        #expect(groups.count == 3)
        queue.heard(text)
        #expect(drain(&queue) == [groups[0].text, groups[1].text])
        #expect(!queue.started.contains(groups[2].text))
    }

    @Test("a group handed out once is not handed out again as the transcript grows")
    func eachGroupOnce() {
        var queue = EarlyCleanupQueue()
        queue.heard(transcript(4, extra: "And then we"))
        let first = drain(&queue)
        #expect(first.count == 1)
        queue.heard(transcript(6, extra: "And then we"))
        let second = drain(&queue)
        #expect(second.count == 1)
        #expect(Set(first).isDisjoint(with: second))
        #expect(queue.started == first + second)
    }

    @Test("with two sightings a group waits until two transcripts in a row show it unchanged")
    func twoSightings() {
        var queue = EarlyCleanupQueue(sightings: 2)
        queue.heard(transcript(4, extra: "And"))
        #expect(queue.next() == nil)
        queue.heard(transcript(4, extra: "And then we went"))
        #expect(drain(&queue).count == 1)
    }

    @Test("a sighting does not count when the group changed in between")
    func sightingsMustBeInARow() {
        var queue = EarlyCleanupQueue(sightings: 2)
        let changed = transcript(6, extra: "And").replacingOccurrences(of: "number 1 is", with: "number one is")
        queue.heard(transcript(6, extra: "And"))
        queue.heard(changed)
        // The first group changed, so it starts counting again; the second group was seen twice.
        let ready = drain(&queue)
        #expect(ready.count == 1)
        #expect(ready.first?.contains("number 3") == true)
    }

    @Test("a waiting group the next transcript no longer has is withdrawn and never handed out")
    func withdrawnWhenTheTranscriptChanges() {
        var queue = EarlyCleanupQueue()
        queue.heard(transcript(6))
        let one = queue.next()
        #expect(one != nil)
        // The recogniser rewrote the second group before its cleaning began.
        queue.heard(transcript(6).replacingOccurrences(of: "number 3 is", with: "number three is"))
        let rest = drain(&queue)
        #expect(rest.count == 1)
        #expect(rest.first?.contains("number three") == true)
        #expect(queue.withdrawn == 1)
    }

    @Test("after the key release nothing more is handed out and later transcripts are ignored")
    func closedAtRelease() {
        var queue = EarlyCleanupQueue()
        queue.heard(transcript(6))
        #expect(queue.next() != nil)
        queue.close()
        #expect(queue.isClosed)
        #expect(queue.next() == nil)
        queue.heard(transcript(8))
        #expect(queue.next() == nil)
        #expect(queue.started.count == 1)
        #expect(queue.transcripts == 1)
    }

    @Test("the same group text said twice is handed out once")
    func repeatedGroupOnce() {
        var queue = EarlyCleanupQueue()
        let pair = sentences[0] + " " + sentences[1]
        queue.heard([pair, pair, pair].joined(separator: " "))
        #expect(drain(&queue) == [pair])
    }
}
