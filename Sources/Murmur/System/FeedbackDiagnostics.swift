import Foundation
import MurmurCore

/// One unified-log entry, as read for the feedback diagnostics file.
struct FeedbackLogLine: Sendable, Equatable {
    let date: Date
    let subsystem: String
    let message: String
}

/// How far back the log could be read: the last three days, or only since Hushy last started
/// (when macOS would not open the full log), or not at all.
enum FeedbackLogReach: Sendable, Equatable {
    case lastThreeDays, thisSession, unavailable
}

/// Everything about this Mac and app that goes in the diagnostics file, apart from the log.
struct FeedbackFacts: Sendable, Equatable {
    enum Permission: Sendable, Equatable {
        case granted, denied, notAsked

        var text: String {
            switch self {
            case .granted: "granted"
            case .denied: "not granted"
            case .notAsked: "not asked yet"
            }
        }
    }

    var version: String
    var build: String
    var macOS: String
    var chip: String
    var memoryGB: Int
    /// The cleanup choice in Settings (`apple`, `local`, `rules`) and what runs now.
    var cleanupSetting: String
    var cleanupInUse: String
    var cleanupModelID: String
    var microphone: Permission
    var accessibility: Permission
}

/// The plain-text file a person can attach to a feedback email and read before sending: app
/// and Mac facts, permission states, and the numbers-only log lines (`FeedbackLogFilter`) from
/// the last three days. No dictated or pasted words, history, dictionary, names, file paths or
/// account details: every value is either rebuilt from known shapes or replaced by "unknown".
enum FeedbackDiagnostics {
    static let window: TimeInterval = 3 * 86_400
    static let subsystem = "app.hushy"
    /// Newest lines kept when a heavy three days logs more than this.
    static let maxLines = 3_000

    static func file(facts: FeedbackFacts, lines: [FeedbackLogLine], reach: FeedbackLogReach, now: Date) -> String {
        let header = [
            "Hushy diagnostics",
            "Written \(timestamp(now)). Numbers and settings only: no words you said or typed.",
            "",
            "App: \(identifier(facts.version)) (\(identifier(facts.build)))",
            "macOS: \(identifier(facts.macOS))",
            "Chip: \(identifier(facts.chip))",
            "Memory: \(max(0, facts.memoryGB)) GB",
            "Cleanup setting: \(identifier(facts.cleanupSetting)), in use: \(identifier(facts.cleanupInUse))",
            "Cleanup model: \(identifier(facts.cleanupModelID))",
            "Microphone access: \(facts.microphone.text)",
            "Accessibility access: \(facts.accessibility.text)",
            "",
            "Log (\(reachTitle(reach))):",
        ]
        let log = safeLines(lines, now: now)
        return (header + (log.isEmpty ? ["No timing lines found."] : log)).joined(separator: "\n") + "\n"
    }

    /// Hushy's own lines from the window, oldest first, each rebuilt by the allowlist.
    static func safeLines(_ lines: [FeedbackLogLine], now: Date) -> [String] {
        let cutoff = now.addingTimeInterval(-window)
        let kept = lines
            .filter { $0.subsystem == subsystem && $0.date >= cutoff && $0.date <= now }
            .sorted { $0.date < $1.date }
            .compactMap { line in FeedbackLogFilter.safe(line.message).map { "\(timestamp(line.date))  \($0)" } }
        return Array(kept.suffix(maxLines))
    }

    private static func reachTitle(_ reach: FeedbackLogReach) -> String {
        switch reach {
        case .lastThreeDays: "last 3 days"
        case .thisSession: "since Hushy last started; macOS did not allow reading further back"
        case .unavailable: "macOS did not allow reading it"
        }
    }

    /// A version, model id or chip name as it is, when it is short and made only of letters,
    /// digits, spaces, dots, dashes and underscores; otherwise "unknown". So a value can never
    /// carry a path, an email address or a sentence into the file.
    static func identifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$"
        return trimmed.range(of: pattern, options: .regularExpression) == nil ? "unknown" : trimmed
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
