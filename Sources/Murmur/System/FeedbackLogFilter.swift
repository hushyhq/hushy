import Foundation
import MurmurCore

/// Rebuilds a log message for the feedback diagnostics file, or drops it. An allowlist, not a
/// scrubber: a line is kept only when its whole shape is one Hushy writes (the key-down timing,
/// the speech gate, the per-dictation timing line), and it is rebuilt from the captured numbers
/// and from fixed words, so nothing else in the message can reach the file. Every other line,
/// including errors that may quote system text, a device name or a path, is left out.
enum FeedbackLogFilter {
    static func safe(_ message: String) -> String? {
        keyDown(message) ?? gate(message) ?? dictation(message)
    }

    private static let number = #"(-?[0-9]+(?:\.[0-9]+)?)"#

    private static func keyDown(_ message: String) -> String? {
        let pattern = #"^key-down: microphone opened in (-?[0-9]+) ms, focused app read in (-?[0-9]+) ms$"#
        guard let v = captures(message, pattern) else { return nil }
        return "key-down: microphone opened in \(v[0]) ms, focused app read in \(v[1]) ms"
    }

    /// The pass/fail word is a plain string interpolation in the app's `Logger` call, which the
    /// unified log stores as `<private>`; that placeholder is kept as it is.
    private static func gate(_ message: String) -> String? {
        let n = number
        let pattern = "^gate (pass|fail|<private>) peak \(n) rms \(n) floor \(n) hi \(n) \\(([0-9]+) frames\\) "
            + "threshold \(n) active ([0-9]+)%$"
        guard let v = captures(message, pattern) else { return nil }
        return "gate \(v[0]) peak \(v[1]) rms \(v[2]) floor \(v[3]) hi \(v[4]) (\(v[5]) frames) threshold \(v[6]) active \(v[7])%"
    }

    /// `dictation 2100 ms audio · speech 80 ms · cleanup 40 ms · insert 9 ms · total 129 ms · model=true why=used · …`
    /// The stage names and numbers are kept; of the tail, only `key=value` tokens whose value
    /// is one the app itself writes (`FeedbackLogTokens`).
    private static func dictation(_ message: String) -> String? {
        let pattern = #"^dictation ([0-9]+) ms audio((?: · (?:speech|cleanup|insert) -?[0-9]+ ms)*) · total (-?[0-9]+) ms(.*)$"#
        guard let v = captures(message, pattern) else { return nil }
        let tokens = v[3].split(whereSeparator: { $0 == " " || $0 == "·" }).map(String.init)
            .filter(FeedbackLogTokens.isKnown)
        let tail = tokens.isEmpty ? "" : " · " + tokens.joined(separator: " ")
        return "dictation \(v[0]) ms audio\(v[1]) · total \(v[2]) ms\(tail)"
    }

    /// The capture groups when `pattern` matches the whole of `text`; nil otherwise.
    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole), match.range == whole else { return nil }
        let source = text as NSString
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}

/// The `key=value` words the dictation log line carries, each with the only values the app
/// writes for it. Anything else (a new token, a changed value) is dropped, never passed through.
enum FeedbackLogTokens {
    private static let values: [String: Set<String>] = [
        "model": ["true", "false"],
        "fallback": ["speed"],
        "thermal": ["nominal", "fair", "serious", "critical", "unknown"],
        "delivery": ["pasted", "pasted-no-return", "return-sent", "return-withheld", "copied", "held", "not-pasted"],
        "reason": ["not-current", "secure-field", "no-field", "dispatch-failed", "cancelled",
                   "paste-unconfirmed", "unconfirmed"],
        "landing": ["confirmed", "unreadable", "not-landed", "cancelled", "not-checked"],
        "clipboard": ["kept", "restored"],
        "focus": ["field", "no-field", "unknown"],
    ]

    static func isKnown(_ token: String) -> Bool {
        if let change = token.wrappedValue(after: "target-changed:") { return isTargetChange(change) }
        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let (key, value) = (parts[0], parts[1])
        switch key {
        case "why": return isWhy(value)
        case "reason":
            if let change = value.wrappedValue(after: "target-changed:") { return isTargetChange(change) }
            return values[key]?.contains(value) == true
        default: return values[key]?.contains(value) == true
        }
    }

    /// `used`, or `rejected-by-guard(added-words)`: a `ModelOutcome`, with a `GuardCode` in brackets.
    private static func isWhy(_ value: String) -> Bool {
        guard let open = value.firstIndex(of: "(") else {
            return ModelOutcome(rawValue: value) != nil
        }
        guard value.hasSuffix(")"), ModelOutcome(rawValue: String(value[..<open])) != nil else { return false }
        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
        return GuardCode(rawValue: String(inner)) != nil
    }

    private static func isTargetChange(_ value: String) -> Bool {
        TargetChange(rawValue: value) != nil
    }
}

private extension String {
    /// The rest of the string after `prefix`, when it starts with it.
    func wrappedValue(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
