import Foundation
import Testing
@testable import Murmur

@Suite("The line of takes being written")
struct TakeLineTests {
    @Test("takes are first in the order they were added, and one that is gone is no longer in line")
    func order() {
        var line = TakeLine()
        let (a, b) = (UUID(), UUID())
        line.append(a)
        line.append(b)
        #expect(line.isFirst(a) && line.isLast(b) && !line.isFirst(b))
        line.remove(a)
        #expect(line.isFirst(b) && line.contains(b) && !line.contains(a))
        line.remove(b)
        #expect(line.isEmpty)
    }

    @Test("an earlier take is left alone until it has run past its own limit, and a take never drops itself")
    func stuckFirstIsDroppedOnlyPastItsLimit() {
        var line = TakeLine()
        let (a, b) = (UUID(), UUID())
        let start = ContinuousClock.now
        line.append(a)
        line.append(b)
        let beforeItStarted = line.dropStuckFirst(for: b, now: start + .seconds(1_000))
        #expect(beforeItStarted == nil, "a take that has not started has no limit yet")
        line.start(a, limit: .seconds(10), now: start)
        let slow = line.dropStuckFirst(for: b, now: start + .seconds(9))
        #expect(slow == nil, "slow is not stuck")
        let itself = line.dropStuckFirst(for: a, now: start + .seconds(11))
        #expect(itself == nil, "a take is not stuck behind itself")
        let stuck = line.dropStuckFirst(for: b, now: start + .seconds(11))
        #expect(stuck == a, "the stuck take is named, so its audio can be kept")
        #expect(line.isFirst(b))
    }
}
