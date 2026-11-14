import Foundation
import Synchronization
import Testing
@testable import MurmurCore

@Suite("Key-down model warm")
struct KeyDownWarmSchedulerTests {
    @Test("schedules once, skips recent and running work, and finishes before a real call")
    func schedulesAndSerializes() async {
        let entered = Mutex(0)
        let active = Mutex(false)
        let scheduler = KeyDownWarmScheduler(interval: .seconds(60)) {
            entered.withLock { $0 += 1 }
            active.withLock { $0 = true }
            defer { active.withLock { $0 = false } }
            try? await Task.sleep(for: .seconds(1))
        }
        let start = ContinuousClock.now
        #expect(scheduler.schedule())
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(!scheduler.schedule())
        await scheduler.beforeRealCall()
        #expect(entered.withLock { $0 } == 1)
        #expect(!active.withLock { $0 })
        #expect(!scheduler.schedule())
    }
}
