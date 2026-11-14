import Foundation

/// When the pill's live draft reads the recording again, and how much of it (`LiveDraftSession`).
///
/// About once a second from the first second, and only ever the last `window` seconds: so the cost of one draft
/// pass is the same in the first minute as in the tenth, and the pill's words lag the voice by about a second.
///
/// Five seconds is the window because the pill shows about five words, which is two seconds of ordinary speech:
/// five seconds gives the recogniser two or three seconds of the sentence before the words it shows (it reads a
/// word better with what came before it), and the recogniser pads anything under one second with silence anyway.
/// Longer only costs more per pass for words the pill never shows.
public struct LiveDraftSchedule: Sendable, Equatable {
    /// Seconds of audio before the first draft.
    public let first: Double
    /// Seconds of audio between two drafts.
    public let gap: Double
    /// Seconds of audio one draft reads: the most recent ones.
    public let window: Double
    /// The audio time the last draft was started (or skipped) at.
    public private(set) var last: Double?

    public init(first: Double = 0.8, gap: Double = 1, window: Double = 5) {
        self.first = first
        self.gap = gap
        self.window = window
    }

    /// Whether a draft is due with `seconds` of audio captured. Ticks arrive about a second apart, so a little
    /// slack keeps a tick that lands a few milliseconds early from waiting a whole extra second.
    public func isDue(at seconds: Double) -> Bool {
        guard seconds >= first else { return false }
        guard let last else { return true }
        return seconds - last >= gap * 0.9
    }

    /// A draft was started, or skipped because the recogniser was busy: the next is a gap later either way.
    public mutating func started(at seconds: Double) {
        last = seconds
    }

    /// The samples one draft reads at `sampleRate`.
    public func windowSamples(sampleRate: Double) -> Int {
        Int(window * sampleRate)
    }
}

/// What of one draft's transcript the pill may show.
public enum LiveDraftText {
    /// The words heard in one window, or nil when there is nothing to show. When the window starts part of the way
    /// into the recording, its first word may have been cut in half and heard as some other word, so it is dropped:
    /// the pill must never show a word that was not said.
    public static func usable(_ heard: String, windowClipped: Bool) -> String? {
        var words = heard.split(whereSeparator: \.isWhitespace)
        if windowClipped { words = Array(words.dropFirst()) }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}
