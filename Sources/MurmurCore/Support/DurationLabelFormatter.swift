import Foundation

/// Formats a recording duration as "10 min" / "45 s" / "1 h 5 min" — units always spelled out,
/// never "10:12", which reads as a clock time next to a real timestamp (audit item "Notes
/// durations"). One place for this so every Notes surface (list row, detail meta line) stays
/// consistent; unit-tested directly rather than only through snapshot review.
public enum DurationLabelFormatter {
    /// - Under 60 seconds: "45 s" (seconds rounded to the nearest whole second; a value that
    ///   rounds up to 60 s is reported as "1 min" instead, so it never reads as "60 s").
    /// - Under 60 minutes: "10 min" (minutes rounded to the nearest whole minute; a value that
    ///   rounds up to 60 min is reported as "1 h" instead, for the same reason).
    /// - 60 minutes and over: "1 h 5 min" (minutes component omitted when it's exactly zero,
    ///   e.g. "2 h").
    public static func label(seconds: Double) -> String {
        let roundedSeconds = Int(max(0, seconds).rounded())
        guard roundedSeconds >= 60 else {
            return "\(roundedSeconds) s"
        }
        let totalMinutes = Int((Double(roundedSeconds) / 60).rounded())
        guard totalMinutes >= 60 else {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
