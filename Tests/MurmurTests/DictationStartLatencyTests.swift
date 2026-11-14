@preconcurrency import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Key-down to microphone-open, through the real event-tap thread and the real dictation start, with a scripted engine
/// that takes as long to build its graph and start as the founder's Mac took on 2026-11-07 (33 starts, `capture timing`
/// log lines, built-in microphone, no voice processing). The device list and Bluetooth facts are read from this Mac
/// (Core Audio reads only); nothing is opened, recorded or stored.
///
/// Opt-in (`HUSHY_START_LATENCY=1`): it is a timing measurement, and the full suite's parallel tests load the main
/// thread it measures.
@Suite("Key-down to microphone open", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["HUSHY_START_LATENCY"] == "1"))
@MainActor
struct DictationStartLatencyTests {
    /// (graph ready, engine started) in ms from the start of `AudioCapture.start`, one pair per real start.
    nonisolated static let measured: [(graph: Double, engine: Double)] = [
        (54, 107), (42, 98), (30, 80), (23, 78), (31, 80), (47, 105), (17, 55), (40, 98), (30, 81), (26, 75), (37, 88),
        (34, 86), (51, 108), (31, 78), (30, 80), (39, 82), (27, 75), (36, 89), (33, 84), (32, 83), (39, 104), (63, 145),
        (39, 104), (23, 74), (30, 87), (28, 80), (32, 97), (36, 86), (30, 84), (27, 76), (35, 81), (38, 97), (35, 87),
    ]
    static let starts = 99

    /// An engine that takes the measured time and delivers nothing.
    final class ReplayEngine: MicrophoneEngine {
        let timing: (graph: Double, engine: Double)
        init(_ timing: (graph: Double, engine: Double)) { self.timing = timing }
        var notificationObject: AnyObject { self }
        var voiceProcessingEnabled: Bool { false }
        func configure(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> AVAudioFormat {
            Thread.sleep(forTimeInterval: timing.graph / 1_000)
            return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        }
        func installTap(_ receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {}
        func start() throws { Thread.sleep(forTimeInterval: (timing.engine - timing.graph) / 1_000) }
        func stop() {}
    }

    final class Engines: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        func make() -> any MicrophoneEngine {
            lock.lock()
            defer { lock.unlock() }
            next += 1
            return ReplayEngine(DictationStartLatencyTests.measured[(next - 1) % DictationStartLatencyTests.measured.count])
        }
    }

    private nonisolated static func fn(down: Bool, stamp: UInt64) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)!
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.timestamp = stamp
        return event
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    /// Holds the main thread for `busy` out of every 16 ms, as a busy interface would.
    private func loadMainThread(busy: Double) -> Timer? {
        guard busy > 0 else { return nil }
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in Thread.sleep(forTimeInterval: busy / 1_000) }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func measure(mainBusy: Double) async throws -> [Int] {
        let harness = try DictationRecoveryControllerTests.Harness()
        harness.modelStatus.markReady()
        let controller = harness.controller
        controller.microphoneGranted = { true }
        controller.microphones = MicrophoneSelector(probe: MicrophoneSelector.liveDevices, followsSystemInput: { false })
        let engines = Engines()
        controller.audio = AudioCapture(makeEngine: { engines.make() }, probe: .live)
        var opened: [Int] = []
        controller.microphoneOpenedForTests = { timing in opened.append(timing.captureMs ?? -1) }
        let thread = EventTapThread()
        thread.start()
        defer { thread.stop() }
        let load = loadMainThread(busy: mainBusy)
        defer { load?.invalidate() }
        for index in 0..<Self.starts {
            let monitor = harness.hotkeys
            // The key goes down now, by the tap's own clock; its release (a 0.5 s hold) is fed once the mic is open.
            let down = mach_absolute_time()
            thread.perform { _ = monitor.receive(type: .flagsChanged, event: Self.fn(down: true, stamp: down)) }
            #expect(await harness.eventually(within: .seconds(5)) { opened.count == index + 1 && !controller.startPending })
            let up = down + UInt64(500e6 * Double(EventClock.timebase.denom) / Double(EventClock.timebase.numer))
            thread.perform { _ = monitor.receive(type: .flagsChanged, event: Self.fn(down: false, stamp: up)) }
            #expect(await harness.eventually(within: .seconds(5)) { !monitor.isDictationActive && !controller.isBusy })
            try await Task.sleep(for: .milliseconds(20))
        }
        return opened
    }

    @Test("key-down to microphone open is at most 150 ms at p95, with the main thread idle or busy 12 ms in every 16")
    func keyDownToMicrophone() async throws {
        for busy in [0.0, 12.0] {
            let opened = try await measure(mainBusy: busy)
            #expect(opened.count == Self.starts && opened.allSatisfy { $0 >= 0 })
            let p50 = percentile(opened, 0.5), p95 = percentile(opened, 0.95)
            print("start latency, main busy \(Int(busy)) ms of 16: n \(opened.count), p50 \(p50) ms, p95 \(p95) ms, max \(opened.max() ?? -1) ms")
            #expect(p95 <= 150, "main busy \(busy) ms of 16: p95 \(p95) ms")
        }
    }
}
