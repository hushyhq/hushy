#if DEBUG
import Foundation
import MurmurCore
import os

/// A side of a recording fed from samples at real time, for the meeting-journal harness: no device, no tap, no
/// permission. It can be told to stall (deliver nothing) or to deliver exact zeros from a moment on, and whether a
/// rebuild cures that, so capture health can be measured against a known fault time.
@MainActor
final class SyntheticNoteSource: NoteAudioSource {
    nonisolated enum Fault: String, Sendable { case none, stall, zeros }

    struct State: Sendable {
        var buffer: [Float] = []
        var position = 0
        var running = false
        var fault = Fault.none
        var level: (@Sendable (Float) -> Void)?
        var sinceLevel = 0
    }

    private let samples: [Float]
    /// Blocks per 20 ms tick: 1 is real time; more plays the call faster than real time (the memory trial's
    /// `--speed`, which fills an hour's journal in minutes to find where finalize memory goes).
    private let speed: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var timer: DispatchSourceTimer?
    /// A rebuild clears the fault (a device that comes back) or leaves it (a dead one).
    var rebuildCures = false
    private(set) var rebuildCount = 0
    nonisolated static let block = 320   // 20 ms at 16 kHz

    init(samples: [Float], speed: Int = 1) {
        self.samples = samples.isEmpty ? [Float](repeating: 0, count: 16_000) : samples
        self.speed = max(1, speed)
    }

    func setFault(_ fault: Fault) { state.withLock { $0.fault = fault } }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        state.withLock {
            $0.running = true
            $0.level = onLevel
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.hushy.synthetic-source"))
        let source = samples
        let state = self.state
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler(handler: Self.deliver(from: source, into: state, blocks: speed))
        timer.resume()
        self.timer = timer
    }

    /// The timer's work, made outside the main actor: it runs on the source's own queue every 20 ms.
    nonisolated private static func deliver(
        from source: [Float], into state: OSAllocatedUnfairLock<State>, blocks: Int
    ) -> @Sendable () -> Void {
        {
            let level = state.withLock { current -> (@Sendable (Float) -> Void, Float)? in
                guard current.running, current.fault != .stall else { return nil }
                let count = Self.block * blocks
                var block = [Float](repeating: 0, count: count)
                if current.fault != .zeros {
                    for index in 0..<count { block[index] = source[(current.position + index) % source.count] }
                }
                current.position = (current.position + count) % source.count
                current.buffer += block
                current.sinceLevel += 1
                guard current.sinceLevel >= 5, let level = current.level else { return nil }
                current.sinceLevel = 0
                return (level, StreamingResampler.rms(block))
            }
            if let (call, rms) = level { call(rms) }
        }
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        state.withLock {
            $0.running = false
            $0.level = nil
        }
    }

    func drain() -> [Float] {
        state.withLock { current in
            defer { current.buffer.removeAll(keepingCapacity: true) }
            return current.buffer
        }
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func rebuild(reason: String) async -> Bool {
        rebuildCount += 1
        if rebuildCures { setFault(.none) }
        return true
    }
}
#endif
