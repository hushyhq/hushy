import Foundation

/// Notices a dead side of a recording within seconds (notes audit B4, meetings schema freeze section 3). Fed once
/// per journal tick with what each side delivered; pure, so the rules are tested without a device.
///
/// - **stall:** a side delivers less than half of the wall-clock samples over `stallWindow` (6 s). The recorder
///   rebuilds that stream and warns.
/// - **digital silence:** a side delivers bit-exact zeros for `zeroWindow` (8 s). A real microphone never does;
///   a dead tap or a muted device does. The call side counts only while the microphone heard someone in that time,
///   because a call's audio is exact zeros whenever nobody on it talks.
/// - Analog quiet (a person listening) is not a fault here: `MeetingCapture`'s 120 s rule covers it.
public struct CaptureHealth: Sendable, Equatable {
    public enum Problem: String, Sendable, Equatable, Codable { case stalled, digitalSilence }

    public struct Event: Sendable, Equatable {
        public let stream: CaptureStream
        /// Nil when the side recovered.
        public let problem: Problem?
        public let at: TimeInterval
    }

    public static let stallWindow: TimeInterval = 6
    public static let stallRatio = 0.5
    public static let zeroWindow: TimeInterval = 8
    public static let sampleRate = 16_000.0

    struct Side: Sendable, Equatable {
        var since: TimeInterval
        var deliveries: [Delivery] = []
        var zerosSince: TimeInterval?
        var lastHeard: TimeInterval?
        var problem: Problem?
    }

    struct Delivery: Sendable, Equatable {
        let at: TimeInterval
        let samples: Int
    }

    private var sides: [CaptureStream: Side] = [:]

    public init(streams: [CaptureStream], startedAt: TimeInterval) {
        for stream in streams { sides[stream] = Side(since: startedAt) }
    }

    public func problem(_ stream: CaptureStream) -> Problem? { sides[stream]?.problem }

    /// The stream was torn down and built again: its stall clock starts over.
    public mutating func restarted(_ stream: CaptureStream, at now: TimeInterval) {
        guard var side = sides[stream] else { return }
        side.since = now
        side.deliveries = []
        sides[stream] = side
    }

    /// One tick's delivery from a side: its sample count, whether every sample was exactly zero, and its RMS.
    public mutating func observe(_ stream: CaptureStream, samples: Int, allZero: Bool, rms: Float, at now: TimeInterval) {
        guard var side = sides[stream] else { return }
        side.deliveries.append(Delivery(at: now, samples: samples))
        side.deliveries.removeAll { $0.at <= now - Self.stallWindow }
        if samples > 0 {
            if allZero { side.zerosSince = side.zerosSince ?? now } else { side.zerosSince = nil }
        }
        if rms >= MeetingCapture.heardFloor { side.lastHeard = now }
        sides[stream] = side
    }

    /// The changes since the last call: a side that went bad, or one that came back.
    public mutating func evaluate(at now: TimeInterval) -> [Event] {
        var events: [Event] = []
        for stream in sides.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var side = sides[stream] else { continue }
            let found = diagnose(stream, side, now: now)
            if found != side.problem {
                events.append(Event(stream: stream, problem: found, at: now))
                side.problem = found
                sides[stream] = side
            }
        }
        return events
    }

    private func diagnose(_ stream: CaptureStream, _ side: Side, now: TimeInterval) -> Problem? {
        // A stalled side stays stalled after a rebuild until it delivers again; a healthy one gets the full window.
        let window = min(Self.stallWindow, now - side.since)
        let wasStalled = side.problem == .stalled
        if window >= Self.stallWindow || (wasStalled && window >= 1) {
            let delivered = side.deliveries.filter { $0.at > now - window }.reduce(0) { $0 + $1.samples }
            if Double(delivered) < Self.stallRatio * window * Self.sampleRate { return .stalled }
        } else if wasStalled {
            return .stalled
        }
        guard let zerosSince = side.zerosSince, now - zerosSince >= Self.zeroWindow else { return nil }
        if stream == .system {
            guard let heard = sides[.mic]?.lastHeard, heard >= zerosSince else { return nil }
        }
        return .digitalSilence
    }
}
