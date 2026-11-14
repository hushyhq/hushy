import Foundation

/// The four read-aloud sentences behind "Tune Hushy to your voice" (onboarding + Settings →
/// re-runnable). Deliberately short — four sentences plus a 2 s silent room-tone capture — but
/// designed to extract maximum signal in that budget:
///
///   1. normal, phonetically rich + a number + a time (tests names, digits, times)
///   2. normal, the user's own jargon (tests domain terms a generic model has never seen)
///   3. whisper (tests the whisper/quiet-input path specifically — see .claude/DECISIONS.md)
///   4. normal with a spoken self-correction (tests `SelfCorrection` cleanup)
///
/// Each sentence has `{placeholders}` filled from up to 5 user-supplied names/terms (prefilled
/// from the existing Dictionary in the UI), falling back to defaults when the user supplies
/// fewer than a sentence needs.
public struct TuneSentence: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case richNormal
        case jargon
        case whisper
        case correction
    }

    public let id: Kind
    /// The literal text to read aloud.
    public let text: String
    /// The expected cleaned-up transcript, used to score the take (see `TuneScorer`).
    public let expected: String
    /// True when this sentence should be recorded as a whisper rather than normal volume.
    public let isWhisper: Bool

    public var index: Int { Self.order.firstIndex(of: id) ?? 0 }

    static let order: [Kind] = [.richNormal, .jargon, .whisper, .correction]
}

/// Builds the four `TuneSentence`s from up to 5 user-supplied names/terms, defaulting anything
/// not supplied so the flow always has something concrete to read.
public enum TuneSentenceBuilder {
    /// Sensible defaults so the flow works even if the user skips naming anyone.
    public static let defaultTerms = ["Alex", "the roadmap", "Jordan", "the deck", "Taylor"]

    /// Builds the four sentences. `terms` should be up to 5 items; shorter lists are padded with
    /// defaults, and empty/blank entries are skipped before padding.
    public static func build(terms: [String]) -> [TuneSentence] {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let padded = Array((cleaned + defaultTerms).prefix(5))
        let name1 = padded[safe: 0] ?? "Alex"
        let name2 = padded[safe: 2] ?? "Jordan"
        let term1 = padded[safe: 1] ?? "the roadmap"
        let term2 = padded[safe: 3] ?? "the deck"

        return [
            TuneSentence(
                id: .richNormal,
                text: "Can you send the invoice to \(name1) by Thursday at 3:30?",
                expected: "Can you send the invoice to \(name1) by Thursday at 3:30?",
                isWhisper: false),
            TuneSentence(
                id: .jargon,
                text: "Let's review \(term1) and \(term2) with \(name2) tomorrow morning.",
                expected: "Let's review \(term1) and \(term2) with \(name2) tomorrow morning.",
                isWhisper: false),
            TuneSentence(
                id: .whisper,
                text: "Just between us, the build is ready to ship.",
                expected: "Just between us, the build is ready to ship.",
                isWhisper: true),
            TuneSentence(
                id: .correction,
                text: "Order twenty five chairs, no, thirty, for the office.",
                expected: "Order thirty chairs for the office.",
                isWhisper: false),
        ]
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
