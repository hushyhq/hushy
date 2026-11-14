import Foundation
import Testing
@testable import HushyModelsMLX

@Suite("MLX pause and recovery")
struct MLXHealthTests {
    private let start = ContinuousClock.now

    @Test("three failures pause the model, and it is asked again when the pause is over")
    func recoversAfterPause() {
        var health = MLXHealth()
        #expect(health.recordFailure("gpu timeout", loadFailed: false, callStarted: start, at: start) == nil)
        #expect(health.recordFailure("gpu timeout", loadFailed: false, callStarted: start, at: start) == nil)
        #expect(health.recordFailure("gpu timeout", loadFailed: false, callStarted: start, at: start) == .seconds(30))
        #expect(health.pauseReason(at: start + .seconds(29)) != nil)
        #expect(health.pauseReason(at: start + .seconds(30)) == nil, "asked again after the pause")
    }

    @Test("a failed load pauses at once; a failure on the next try pauses again for longer, up to the cap")
    func backsOff() {
        var health = MLXHealth()
        var now = start
        var pauses: [Duration] = []
        for _ in 0..<8 {
            if let pause = health.recordFailure("Insufficient Memory", loadFailed: true, callStarted: now, at: now) { pauses.append(pause) }
            now += pauses.last ?? .zero
        }
        #expect(pauses == [.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(600), .seconds(600), .seconds(600)])
    }

    @Test("a success after a pause ends the backoff: the next pause needs three failures again and starts short")
    func successResets() {
        var health = MLXHealth()
        _ = health.recordFailure("x", loadFailed: true, callStarted: start, at: start)
        health.recordSuccess(callStarted: start + .seconds(1))
        #expect(health.pauseReason(at: start) == nil)
        #expect(health.recordFailure("x", loadFailed: false, callStarted: start, at: start) == nil)
        #expect(health.recordFailure("x", loadFailed: false, callStarted: start, at: start) == nil)
        #expect(health.recordFailure("x", loadFailed: false, callStarted: start, at: start) == .seconds(30))
    }

    @Test("a call already running when the pause began neither lengthens it nor ends it")
    func inFlightCall() {
        var health = MLXHealth()
        let paused = start + .seconds(1)
        #expect(health.recordFailure("x", loadFailed: true, callStarted: paused, at: paused) == .seconds(30))
        #expect(health.recordFailure("x", loadFailed: false, callStarted: start, at: paused + .seconds(2)) == nil)
        health.recordSuccess(callStarted: start)
        #expect(health.pauseReason(at: paused + .seconds(29)) != nil, "a late success leaves the pause in place")
        #expect(health.pauseReason(at: paused + .seconds(30)) == nil, "the pause was not doubled")
        #expect(health.recordFailure("x", loadFailed: false, callStarted: paused + .seconds(30), at: paused + .seconds(31)) == .seconds(60),
                "a call after the pause is the trial, and its failure backs off")
    }
}
