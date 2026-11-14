import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The event tap's own thread (audit 2026-11-07, B2): stamped synthetic events go through the tap's
/// path (`HotkeyMonitor.receive`) on a real `EventTapThread`, while the main thread is held the way a
/// slow dictation start holds it. No real tap, microphone or app.
@Suite("The event tap judges keys on its own thread", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EventTapThreadTests {
    /// One double tap and the tap that ends hands-free, in milliseconds from the cycle's start.
    nonisolated static let cycle: [(ms: Double, down: Bool)] = [(0, true), (80, false), (200, true), (280, false), (800, true), (860, false)]
    nonisolated static let cycleLength: Double = 1_000
    nonisolated static let cycles = 100

    /// Collects deliveries on the main actor and holds the main thread on the first one.
    final class MainSide {
        var delivered: [(HotkeyEvent, Date)] = []
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    /// What the tap thread saw: each callback's answer and how long it took.
    final class TapSide: @unchecked Sendable {
        var swallowed: [Bool] = []
        var callbackMilliseconds: [Double] = []
        var firstUseMilliseconds = 0.0
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private nonisolated static func fnEvent(down: Bool, stamp: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)!
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.timestamp = stamp
        return event
    }

    /// The clocks `late` ms after `ms` into the script, as the tap would read them.
    private nonisolated static func reading(_ start: EventClock.Reading, at ms: Double, late: Double) -> EventClock.Reading {
        let elapsed = ms + late
        let ticksPerMillisecond = 1e6 * Double(EventClock.timebase.denom) / Double(EventClock.timebase.numer)
        return EventClock.Reading(
            date: start.date.addingTimeInterval(elapsed / 1_000),
            uptimeNanoseconds: start.uptimeNanoseconds + UInt64(elapsed * 1e6),
            machTicks: start.machTicks + UInt64(elapsed * ticksPerMillisecond))
    }

    private nonisolated static func stamp(_ start: EventClock.Reading, at ms: Double) -> UInt64 {
        start.machTicks + UInt64(ms * 1e6 * Double(EventClock.timebase.denom) / Double(EventClock.timebase.numer))
    }

    private func eventually(within limit: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test("100 of 100 double taps are judged right from their stamps while the main thread is blocked, each read up to 300 ms late")
    func doubleTapsWhileMainIsBlocked() async {
        let monitor = HotkeyMonitor()
        let thread = EventTapThread()
        thread.start()
        defer { thread.stop() }
        let main = MainSide()
        monitor.onTimedEvent = { event, time in
            if main.delivered.isEmpty {
                // The first press holds the main thread as a slow microphone start would, until the
                // tap thread has judged every other event.
                main.blocked.signal()
                _ = main.release.wait(timeout: .now() + 30)
            }
            main.delivered.append((event, time))
        }
        let start = EventClock.Reading.now()
        let tap = TapSide()
        let events = (0..<Self.cycles).flatMap { cycle in
            Self.cycle.map { (ms: Double(cycle) * Self.cycleLength + $0.ms, down: $0.down) }
        }
        let blocked = main.blocked, release = main.release
        thread.perform {
            // The process's first trip through the tap path pays one-time costs (the Swift runtime's
            // first type lookups, the logger) that no later key pays; a throwaway monitor pays them here.
            let warm = HotkeyMonitor()
            let first = ContinuousClock.now
            _ = warm.receive(type: .flagsChanged, event: Self.fnEvent(down: true, stamp: 0))
            tap.firstUseMilliseconds = Self.milliseconds(ContinuousClock.now - first)
            for (index, step) in events.enumerated() {
                // Every read is late by its own amount, so press and release are read at different delays.
                let late = Double((index * 3) % 7) * 50
                monitor.tapClock = { Self.reading(start, at: step.ms, late: late) }
                let began = ContinuousClock.now
                let swallowed = monitor.receive(type: .flagsChanged, event: Self.fnEvent(down: step.down, stamp: Self.stamp(start, at: step.ms)))
                tap.callbackMilliseconds.append(Self.milliseconds(ContinuousClock.now - began))
                tap.swallowed.append(swallowed)
                if index == 0 { _ = blocked.wait(timeout: .now() + 10) }
            }
            release.signal()
        }

        #expect(await eventually { main.delivered.count >= 3 * Self.cycles })
        let expected = (0..<Self.cycles).flatMap { cycle -> [(HotkeyEvent, Date)] in
            let base: Double = Double(cycle) * Self.cycleLength
            let steps: [(HotkeyEvent, Double)] = [(.pressed, base), (.latched, base + 80), (.stopLatched, base + 800)]
            return steps.map { event, ms in (event, start.date.addingTimeInterval(ms / 1_000)) }
        }
        let correct = zip(main.delivered, expected).filter { got, want in
            got.0 == want.0 && abs(got.1.timeIntervalSince(want.1)) < 0.001
        }.count
        #expect(main.delivered.count == expected.count)
        #expect(correct == expected.count, "\(correct / 3) of \(Self.cycles) double taps judged and timed right")
        #expect(tap.swallowed.count == events.count && tap.swallowed.allSatisfy { $0 },
                "every solo fn event is hidden from macOS")
        let slowest = tap.callbackMilliseconds.max() ?? .infinity
        let sorted = tap.callbackMilliseconds.sorted()
        print("tap callbacks: n \(sorted.count), p50 \(sorted[sorted.count / 2]) ms, p99 \(sorted[sorted.count * 99 / 100]) ms, max \(slowest) ms at \(tap.callbackMilliseconds.firstIndex(of: slowest) ?? -1); first use \(tap.firstUseMilliseconds) ms")
        // Main is blocked for the whole run, so a slow callback here is the scheduler, never the main thread: the
        // bound on the slowest leaves room for a loaded test machine; the 99th percentile is the claim.
        #expect(slowest < 50 && sorted[sorted.count * 99 / 100] < 5,
                "no callback waited on the blocked main thread (slowest \(slowest) ms)")
    }

    @Test("with the main thread blocked, esc under a pill question goes to the app after the short wait")
    func pillQuestionWithMainBlocked() {
        let monitor = HotkeyMonitor()
        let thread = EventTapThread()
        thread.start()
        defer { thread.stop() }
        monitor.pillKeyScope = { .confirm }
        monitor.pillKeysPossible = true
        final class Result: @unchecked Sendable { var swallowed: Bool?; var milliseconds = 0.0 }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            let esc = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)!
            let began = ContinuousClock.now
            result.swallowed = monitor.receive(type: .keyDown, event: esc)
            result.milliseconds = Double(CaptureTiming.milliseconds(ContinuousClock.now - began))
            done.signal()
        }
        // The main thread is held here, so the tap thread's question about the pill gets no answer.
        _ = done.wait(timeout: .now() + 5)
        #expect(result.swallowed == false, "a key Hushy cannot judge reaches the app")
        #expect(result.milliseconds < 200, "and waits at most about \(HotkeyMonitor.pillScopeWait)")
    }

    @Test("with the main thread free, esc under a pill question is the pill's and reaches it after the tap returns")
    func pillQuestionWithMainFree() async {
        let monitor = HotkeyMonitor()
        let thread = EventTapThread()
        thread.start()
        defer { thread.stop() }
        monitor.pillKeyScope = { .confirm }
        monitor.pillKeysPossible = true
        var answered: [PillKey] = []
        monitor.onPillKey = { answered.append($0) }
        final class Result: @unchecked Sendable { var swallowed: Bool? }
        // Other suites may hold the main thread for longer than the tap waits; each such esc goes to the app and
        // the pill hears nothing of it. Press again until one lands while the main thread is free.
        var swallowed = false
        for _ in 0..<50 where !swallowed {
            let result = Result()
            thread.perform {
                let esc = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)!
                result.swallowed = monitor.receive(type: .keyDown, event: esc)
            }
            _ = await eventually { result.swallowed != nil }
            swallowed = result.swallowed == true
        }
        #expect(swallowed)
        #expect(await eventually { answered == [.dismiss] }, "the one esc the pill took reached it, once")
    }

    @Test("while the pill asks nothing, ⏎ and esc never wait on the main thread")
    func noPillQuestionAsksNothing() {
        let monitor = HotkeyMonitor()
        let thread = EventTapThread()
        thread.start()
        defer { thread.stop() }
        final class Asked: @unchecked Sendable { var count = 0 }
        let asked = Asked()
        monitor.pillKeyScope = { asked.count += 1; return .confirm }
        monitor.pillKeysPossible = false
        final class Result: @unchecked Sendable { var swallowed: [Bool] = [] }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            for code in [kVK_Return, kVK_Escape, kVK_ANSI_KeypadEnter] {
                let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
                result.swallowed.append(monitor.receive(type: .keyDown, event: key))
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        #expect(result.swallowed == [false, false, false])
        #expect(asked.count == 0)
    }
}
