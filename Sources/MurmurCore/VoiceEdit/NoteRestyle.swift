import CryptoKit
import Foundation

/// Restyle a note after the fact (founder, 2026-11-07): a memo is written in the default Refined style, and from the
/// note's page the person can show that one note as Professional or Casual, and go back. Live dictation never goes
/// through here.
///
/// The rewrite is `SelectionRestyler`'s, piece by piece, so the same guard decides (`VoiceEditGuard`: a dropped "not",
/// a changed name or changed digits keeps the original). One refused piece keeps the whole note as it was: a note is
/// never shown half in one style and half in another.
///
/// The stored text is never written: the versions live beside the note (`NoteStyleFile`), so Refined is always the
/// note's own transcript, one tap away.
public enum NoteRestyle {
    /// The styles a note offers, in the control's order. Refined is the stored text itself.
    public static let styles: [RestyleStyle] = [.refined, .professional, .casual]

    /// The longest body restyled, about half an hour of speech. The control says so beyond it instead of
    /// keeping the text covered for many minutes.
    public static let maxCharacters = 24_000

    /// The most characters sent to the model at once: well inside the voice edit's own limit
    /// (`SelectedText.maxCharacters`) and its longest wait (`VoiceEditor.budget`).
    public static let pieceCharacters = 1_500

    /// Whether a note's body may be restyled, and if not, why.
    public enum Availability: Sendable, Equatable {
        case available
        /// A meeting: its transcript is what people said and stays near-verbatim (founder, 2026-11-07).
        case meeting
        /// An imported file is often a recorded call or a talk; the data cannot tell, so it stays as transcribed.
        case imported
        /// Still recording, transcribing or incomplete.
        case notReady
        case empty
        case tooLong
    }

    /// A memo is a note started by hand, recorded on this Mac, with one voice and nothing that marks a call: no call
    /// app, no recording consent, no calendar event. Anything else is treated as a meeting and left as transcribed.
    public static func availability(
        of note: Note, hasSeveralVoices: Bool, hasConsent: Bool, hasCalendarLink: Bool
    ) -> Availability {
        if note.meetingApp != nil || hasSeveralVoices || hasConsent || hasCalendarLink { return .meeting }
        if note.source == .file { return .imported }
        guard note.status == .ready else { return .notReady }
        let body = note.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return .empty }
        if body.count > maxCharacters { return .tooLong }
        return .available
    }

    /// How one restyle of a note ended.
    public enum Outcome: Sendable, Equatable {
        case rewritten(String)
        /// The note stays as it was. `.unchanged` when every piece already read that way.
        case kept(VoiceEditDecline)
        /// Dictation or a recording started: the rewrite stopped between pieces and nothing changed.
        case paused
        case tooLong
    }

    /// Rewrites `body` in `style`, one piece at a time through `SelectionRestyler`. Before each piece it asks
    /// `shouldContinue`, so dictation never waits behind more than one piece. Refined is the body itself.
    public static func restyle(
        _ body: String, as style: RestyleStyle, model: any LanguageModel,
        shouldContinue: @Sendable () async -> Bool = { true }
    ) async -> Outcome {
        guard style != .refined else { return .rewritten(body) }
        guard body.count <= maxCharacters else { return .tooLong }
        var written: [Piece] = []
        var changed = false
        for piece in pieces(of: body) {
            guard !piece.text.isEmpty else {
                written.append(piece)
                continue
            }
            guard await shouldContinue() else { return .paused }
            switch await SelectionRestyler.restyle(piece.text, as: style, model: model) {
            case .rewritten(let text):
                changed = true
                written.append(Piece(text: text.trimmingCharacters(in: .whitespacesAndNewlines), separator: piece.separator))
            // A short piece that already reads this way ("Thanks.") stays as it is; the rest still changes.
            case .kept(.unchanged):
                written.append(piece)
            case .kept(let why):
                return .kept(why)
            }
        }
        return changed ? .rewritten(join(written)) : .kept(.unchanged)
    }

    /// One part of the body and what followed it in the body ("\n" between lines, " " between sentences).
    struct Piece: Sendable, Equatable {
        var text: String
        var separator: String
    }

    /// The body as pieces of at most `limit` characters: whole lines when they fit, else whole sentences packed
    /// together. A single sentence longer than the limit is its own piece (the voice edit's limit is four times
    /// higher). Joining the pieces gives the body back with its line breaks. One pass, O(n).
    static func pieces(of body: String, limit: Int = pieceCharacters) -> [Piece] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pieces: [Piece] = []
        for (index, line) in lines.enumerated() {
            let lineEnd = index == lines.count - 1 ? "" : "\n"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > limit else {
                pieces.append(Piece(text: trimmed, separator: lineEnd))
                continue
            }
            var current = ""
            for sentence in Sentences.split(trimmed) {
                if !current.isEmpty, current.count + 1 + sentence.count > limit {
                    pieces.append(Piece(text: current, separator: " "))
                    current = ""
                }
                current = current.isEmpty ? sentence : current + " " + sentence
            }
            pieces.append(Piece(text: current, separator: lineEnd))
        }
        return pieces
    }

    static func join(_ pieces: [Piece]) -> String {
        pieces.map { $0.text + $0.separator }.joined()
    }
}

/// Which way a note is shown, and the versions already written for it. A value: every change returns a new one.
/// Saved beside the note (`NoteStyleFile`) so it survives a relaunch; the note's stored text is never touched.
public struct NoteStyleState: Codable, Sendable, Equatable {
    public static let currentFormat = 1
    /// How many steps Undo can go back.
    public static let undoDepth = 20

    public private(set) var format: Int
    /// The SHA-256 of the body the versions were written from. When the note's text changes (a retry transcribes it
    /// again) the versions no longer fit it, and the note reads as Refined again.
    public let base: String
    public private(set) var style: RestyleStyle
    /// Written versions by `RestyleStyle.rawValue`. Never holds Refined: that is the note's own text.
    private var versions: [String: String]
    /// The styles Undo goes back through, most recent last.
    public private(set) var history: [RestyleStyle]

    /// A note shown as it was written.
    public init(body: String) {
        format = Self.currentFormat
        base = Self.fingerprint(body)
        style = .refined
        versions = [:]
        history = []
    }

    public static func fingerprint(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether these versions were written from `body`.
    public func fits(_ body: String) -> Bool { base == Self.fingerprint(body) }

    /// The text to show for `body`: the version in the current style, or the body itself.
    public func text(body: String) -> String {
        guard style != .refined, fits(body) else { return body }
        return versions[style.rawValue] ?? body
    }

    /// The version already written in `style`, if any. Refined has none: it is the body.
    public func version(_ style: RestyleStyle) -> String? {
        style == .refined ? nil : versions[style.rawValue]
    }

    /// Whether `style` can be shown without asking the model.
    public func hasVersion(_ style: RestyleStyle) -> Bool { style == .refined || versions[style.rawValue] != nil }

    /// Shown in `style`, keeping `text` as its version when given. The style shown before goes onto Undo. A style
    /// with no version and no text is refused: the same state comes back.
    public func showing(_ style: RestyleStyle, text: String? = nil) -> NoteStyleState {
        var next = self
        if let text, style != .refined { next.versions[style.rawValue] = text }
        guard next.hasVersion(style), style != self.style else { return next }
        next.history = Array((history + [self.style]).suffix(Self.undoDepth))
        next.style = style
        return next
    }

    public var canUndo: Bool { !history.isEmpty }

    /// The style shown before the last change. The versions stay, so Redo is just picking the style again.
    public func undone() -> NoteStyleState {
        guard let previous = history.last else { return self }
        var next = self
        next.history.removeLast()
        next.style = next.hasVersion(previous) ? previous : .refined
        return next
    }
}

extension RestyleStyle: Codable {}

/// Every string the note restyle shows. Placeholders until the founder writes the copy.
public enum NoteRestyleCopy {
    public static let controlLabel = "[placeholder] How do you want it?"
    public static let rewriting = "[placeholder] Rewriting on this Mac…"
    public static let rewritingDetail = "[placeholder] Pauses while you dictate · Esc to stop"
    public static let stop = "[placeholder] Stop"
    public static let undo = "[placeholder] Undo"
    public static let backToRefined = "[placeholder] Back to Refined"
    public static let originalKept = "[placeholder] Your original is kept"
    public static let paused = "[placeholder] Paused while you dictate · text kept"
    public static let tooLong = "[placeholder] This note is too long to restyle"

    public static func style(_ style: RestyleStyle) -> String {
        switch style {
        case .refined: "[placeholder] Refined"
        case .professional: "[placeholder] Professional"
        case .casual: "[placeholder] Casual"
        case .prompt: "[placeholder] Prompt"
        }
    }

    /// The line under the control: which style the note is shown in.
    public static func shownAs(_ style: RestyleStyle) -> String {
        style == .refined ? "[placeholder] Shown as written" : "[placeholder] Shown as \(Self.styleName(style))"
    }

    /// Why the note was kept as it was.
    public static func kept(_ why: VoiceEditDecline) -> String {
        switch why {
        case .wouldChangeMeaning: "[placeholder] That would change a name, a number or a \u{201C}not\u{201D} · text kept"
        case .unchanged: "[placeholder] It already reads that way"
        case .cannotDo, .noAnswer: "[placeholder] Couldn't rewrite it right now · text kept"
        }
    }

    private static func styleName(_ style: RestyleStyle) -> String {
        switch style {
        case .refined: "Refined"
        case .professional: "Professional"
        case .casual: "Casual"
        case .prompt: "Prompt"
        }
    }
}
