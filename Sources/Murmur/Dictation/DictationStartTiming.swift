import Foundation

/// How long one dictation took to start, counted from the moment its key event happened (the event's own
/// time stamp, so any wait before the controller saw it is counted too): when the microphone start returned, when the pill was told to show, and
/// when the first audio arrived. Logged once per dictation, numbers only:
///
///     dictation start pillMs=31 captureMs=29 audioMs=118
///
/// `pillMs` is when the pill's state was set; it draws on the next frame. The pill is shown before the
/// microphone opens (`DictationController.begin`), so `pillMs` is the key-down-to-pill time and `captureMs`
/// is later. A recording that ends before any audio arrives logs `audioMs=-`. Measuring adds three clock
/// reads and moves nothing.
struct DictationStartTiming: Equatable, Sendable {
    let began: ContinuousClock.Instant
    private(set) var captureMs: Int?
    private(set) var pillMs: Int?
    private(set) var audioMs: Int?
    private(set) var isLogged = false

    init(began: ContinuousClock.Instant = .now) {
        self.began = began
    }

    /// Counts from `keyEvent`, the time stamp of the key press, not from the moment the controller got to it.
    /// A time stamp in the future (a clock that stepped back) counts as now.
    init(keyEvent: Date, now: Date = Date(), clock: ContinuousClock.Instant = .now) {
        let waited = max(0, now.timeIntervalSince(keyEvent))
        self.init(began: clock - .milliseconds(Int((waited * 1_000).rounded())))
    }

    /// The microphone start returned.
    mutating func captureStarted(at now: ContinuousClock.Instant = .now) {
        if captureMs == nil { captureMs = milliseconds(to: now) }
    }

    /// The pill was told to show Listening.
    mutating func pillShown(at now: ContinuousClock.Instant = .now) {
        if pillMs == nil { pillMs = milliseconds(to: now) }
    }

    /// An audio level arrived. Returns the line to log the first time, then nil.
    mutating func audioArrived(at now: ContinuousClock.Instant = .now) -> String? {
        guard !isLogged else { return nil }
        audioMs = milliseconds(to: now)
        return logOnce()
    }

    /// The recording ended. Returns the line if it was never logged (no audio ever arrived), else nil.
    mutating func ended() -> String? {
        logOnce()
    }

    /// The whole line. A step that did not happen prints a dash.
    var line: String {
        "dictation start pillMs=\(Self.field(pillMs)) captureMs=\(Self.field(captureMs)) audioMs=\(Self.field(audioMs))"
    }

    private mutating func logOnce() -> String? {
        guard !isLogged else { return nil }
        isLogged = true
        return line
    }

    private func milliseconds(to now: ContinuousClock.Instant) -> Int {
        let elapsed = began.duration(to: now)
        return max(0, Int((Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15).rounded()))
    }

    private static func field(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }
}
