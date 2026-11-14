import Foundation

/// What the UI shows while the speech model downloads: a byte-weighted fraction (FluidAudio
/// reports bytes-received / bytes-expected across the repo's files), the files completed so
/// far, and a time-remaining estimate derived from the observed rate.
///
/// Bytes are *estimated* as `fraction × expectedBytes`: FluidAudio's progress callback carries
/// the byte-weighted fraction but not the byte counts themselves, and `expectedBytes` is the
/// measured on-disk size of the model (see `SpeechEngine.expectedDownloadBytes`). The bar and
/// the percentage are tied to real bytes received; the "N MB of M MB" text is labelled "about"
/// because M is a constant, not the server's content-length.
public struct ModelDownloadProgress: Equatable, Sendable {
    /// 0…1 of the download phase only (compilation/loading is a separate state).
    public let fraction: Double
    public let expectedBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    /// Estimated seconds remaining from the recent transfer rate; nil until enough samples
    /// have arrived to say something honest (see `DownloadRateEstimator`).
    public let estimatedSecondsRemaining: TimeInterval?

    public init(fraction: Double, expectedBytes: Int64, completedFiles: Int = 0, totalFiles: Int = 0,
                estimatedSecondsRemaining: TimeInterval? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.expectedBytes = max(expectedBytes, 0)
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }

    public var estimatedBytes: Int64 { Int64((Double(expectedBytes) * fraction).rounded()) }

    public var percent: Int { Int((fraction * 100).rounded(.down)) }

    /// "42%"
    public var percentText: String { "\(percent)%" }

    /// "195 MB of about 465 MB"
    public var bytesText: String {
        "\(Self.formatBytes(estimatedBytes)) of about \(Self.formatBytes(expectedBytes))"
    }

    /// "about 40 s left", "about 2 min left", or "estimating…" before a rate exists.
    public var remainingText: String {
        guard let seconds = estimatedSecondsRemaining else { return "estimating time left…" }
        return "about \(Self.formatRemaining(seconds)) left"
    }

    /// "2 of 4 files" when the phase reports file counts, otherwise nil.
    public var filesText: String? {
        guard totalFiles > 0 else { return nil }
        return "\(min(completedFiles, totalFiles)) of \(totalFiles) files"
    }

    /// One line for compact places (menu bar, Settings): "Downloading speech model · 42% · about 40 s left".
    public var summaryLine: String {
        "Downloading speech model · \(percentText) · \(remainingText)"
    }

    /// The one-line Afterglow form: "Speech model · 312 of ~632 MB · about 4 min". Bytes, not a
    /// percentage (bytes only ever go up; a percentage invites comparing ticks), "~" on the total
    /// because it is the measured model size rather than the server's content-length, and the
    /// time part only once there is an honest estimate.
    public func compactLine(title: String) -> String {
        let received = Self.formatBytes(estimatedBytes)
        let total = Self.formatBytes(expectedBytes)
        let receivedNumber = received.hasSuffix(" MB") && total.hasSuffix(" MB") ? String(received.dropLast(3)) : received
        var line = "\(title) · \(receivedNumber) of ~\(total)"
        if let seconds = estimatedSecondsRemaining { line += " · about \(Self.formatRemaining(seconds))" }
        return line
    }

    /// Decimal megabytes, matching what Finder and the download page show ("465 MB"), with
    /// one decimal below 10 MB so the first seconds of a download visibly move.
    public static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1_000 { return String(format: "%.2f GB", mb / 1_000) }
        if mb < 10 { return String(format: "%.1f MB", mb) }
        return "\(Int(mb.rounded())) MB"
    }

    /// Coarse on purpose: a download ETA jitters, and "about 40 s" reads more honestly than
    /// "37 s" ticking around. Under a minute rounds to 5 s; over, to the minute.
    public static func formatRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return "10 s" }
        if seconds < 60 { return "\(Int((seconds / 5).rounded(.up)) * 5) s" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

/// Turns a stream of (fraction, time) samples into a bytes-per-second rate over a sliding
/// window, so the ETA reflects the last several seconds rather than the whole download (which
/// would understate a connection that ramps up) or the last tick (which would jitter).
/// Value type: every observation returns a new estimator.
public struct DownloadRateEstimator: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let fraction: Double
        public let time: Date
    }

    public let expectedBytes: Int64
    public let window: TimeInterval
    /// Minimum span of samples before an estimate is offered; before that the UI says
    /// "estimating…" instead of extrapolating from a single tick.
    public let minimumSpan: TimeInterval
    public private(set) var samples: [Sample]

    public init(expectedBytes: Int64, window: TimeInterval = 10, minimumSpan: TimeInterval = 2, samples: [Sample] = []) {
        self.expectedBytes = expectedBytes
        self.window = window
        self.minimumSpan = minimumSpan
        self.samples = samples
    }

    /// Records one progress tick, dropping samples older than `window` (but always keeping
    /// the newest two so a rate can still be computed on a slow connection).
    public func observing(fraction: Double, at time: Date) -> DownloadRateEstimator {
        var kept = samples.filter { time.timeIntervalSince($0.time) <= window }
        if kept.count < 2, let last = samples.last, !kept.contains(last) { kept.insert(last, at: 0) }
        kept.append(Sample(fraction: min(max(fraction, 0), 1), time: time))
        return DownloadRateEstimator(expectedBytes: expectedBytes, window: window, minimumSpan: minimumSpan, samples: kept)
    }

    /// Bytes per second over the retained window; nil until `minimumSpan` of samples exists
    /// or if no bytes arrived in that span.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= minimumSpan else { return nil }
        let bytes = Double(expectedBytes) * (last.fraction - first.fraction)
        guard bytes > 0 else { return nil }
        return bytes / span
    }

    /// Seconds to reach 100% at the current rate; nil when there is no rate yet.
    public var estimatedSecondsRemaining: TimeInterval? {
        guard let rate = bytesPerSecond, let last = samples.last else { return nil }
        let remaining = Double(expectedBytes) * (1 - last.fraction)
        return remaining / rate
    }
}
