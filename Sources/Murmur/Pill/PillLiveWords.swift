import AppKit
import SwiftUI

/// A hidden comparison switch (`pillLiveVariant` in the app's defaults domain).
///
/// - `waveAndWords` (default): the listening bars stay on the left and the words run beside them; after the release
///   the bars fold into the three writing dots and the words carry on beside them.
/// - `wordsOnly`: one small dot (lime while listening, purple while writing) and the words take the rest of the room.
enum PillLiveVariant: String, CaseIterable {
    case waveAndWords
    case wordsOnly

    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: "pillLiveVariant") ?? "") ?? .waveAndWords
    }
}

/// The words in the pill while a dictation is spoken and written. In memory only: never logged, never stored, and
/// gone once the pill leaves listening and writing (`changed(to:from:)`).
struct PillLiveState: Equatable {
    /// The latest live draft's words (`LiveDraftSession`), kept into the wait after the release.
    private(set) var heard: String?
    /// The cleaned text of the latest finished sentence group, while a long dictation is written.
    private(set) var settled: String?
    /// The capsule has grown to the live width. Set by the first words and kept until listening and writing end, so
    /// the width never follows the text.
    private(set) var isWide = false

    /// More words than the widest pill shows, so the view can fit the most that fit.
    static let keptWords = 12

    mutating func hear(_ text: String) {
        guard let tail = PillLiveWords.tail(text, count: Self.keptWords) else { return }
        heard = tail
        isWide = true
    }

    mutating func settle(_ text: String) {
        settled = PillLiveWords.tail(text, count: Self.keptWords) ?? settled
    }

    /// Keeps the words through listening and on into writing; anything else (a new recording included) drops them.
    mutating func changed(to state: PillState, from old: PillState) {
        switch state {
        case .listening, .handsFree: if !old.showsDictationBars { self = PillLiveState() }
        case .processing where old.isWriting: return
        case .processing where old.showsDictationBars: settled = nil
        default: self = PillLiveState()
        }
    }

    mutating func typing() { settled = nil }
}

extension PillState {
    var isWriting: Bool {
        if case .processing = self { return true }
        return false
    }
}

enum PillLiveWords {
    /// The pill's text style (the writing label's), measured here to fit whole words.
    static let font = Font.system(size: 11, weight: .medium)
    /// The capsule while words show: room for about five ordinary words beside the bars.
    static let capsule = CGSize(width: 276, height: PillMetrics.listening.height)
    static let gap: CGFloat = 10
    static let dotSize: CGFloat = 6
    /// The bars' own width, so the words never move when the bars fold into dots.
    static var barsWidth: CGFloat { PillFold.barsWidth(.dictation) }

    /// The room the words have beside the marker (the capsule less its padding, the marker and the gap).
    static func textWidth(_ variant: PillLiveVariant, padding: CGFloat = 10) -> CGFloat {
        capsule.width - 2 * padding - gap - (variant == .waveAndWords ? barsWidth : dotSize)
    }

    /// The last `count` words, or nil when there are none.
    static func tail(_ text: String?, count: Int) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.suffix(count).joined(separator: " ")
    }

    /// The words while writing: the cleaned group when there is one, else what the release pass heard (`ink`), else
    /// the last live draft.
    static func writing(settled: String?, ink: String?, heard: String?) -> String? {
        tail(settled, count: PillLiveState.keptWords) ?? tail(ink, count: PillLiveState.keptWords) ?? heard
    }

    /// The most trailing whole words that fit `width`, with a leading "…" when older words were dropped. The newest
    /// word is always at the right end of the text.
    static func visible(_ text: String, width: CGFloat) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let room = width - 2 // SwiftUI's text is a hair wider than AppKit measures it
        for count in stride(from: words.count, through: 1, by: -1) {
            let candidate = (count < words.count ? "…" : "") + words.suffix(count).joined(separator: " ")
            if (candidate as NSString).size(withAttributes: [.font: font]).width <= room { return candidate }
        }
        return words.last ?? ""
    }
}

/// The marker and the words, at fixed widths: the words start right after the marker, and once they fill the room
/// the oldest drop off the left. Hidden from VoiceOver, which reads the pill's own label and not each update.
struct PillLiveRow<Marker: View>: View {
    let text: String
    let variant: PillLiveVariant
    let tint: Color
    @ViewBuilder let marker: () -> Marker

    var body: some View {
        HStack(spacing: PillLiveWords.gap) {
            marker()
                .frame(width: variant == .waveAndWords ? PillLiveWords.barsWidth : PillLiveWords.dotSize)
            PillLiveText(text: text, width: PillLiveWords.textWidth(variant), tint: tint).equatable()
        }
        .accessibilityHidden(true)
    }
}

/// The words alone, a view of plain values so SwiftUI skips it (and its measuring) while only the bars move.
private struct PillLiveText: View, Equatable {
    let text: String
    let width: CGFloat
    let tint: Color
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.width == rhs.width && lhs.tint == rhs.tint
    }

    var body: some View {
        Text(PillLiveWords.visible(text, width: width))
            .font(PillLiveWords.font)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(width: width, alignment: .leading)
            .contentTransition(.opacity)
            // New words fade in; under Reduce Motion they simply replace the old.
            .animation(reduceMotion ? nil : motion.animation(.fade), value: text)
    }
}

/// The words-only marker: a small dot, lime while the microphone hears (brighter with the voice), purple once the
/// words are being written.
struct PillLiveDot: View {
    var level: Double?

    var body: some View {
        Circle()
            .fill(level == nil ? Theme.pillWorking : Theme.phosphorFill)
            .opacity(level.map { 0.55 + 0.45 * min(1, $0 * 1.6) } ?? 1)
            .frame(width: PillLiveWords.dotSize, height: PillLiveWords.dotSize)
    }
}
