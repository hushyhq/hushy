import MurmurCore
import SwiftUI

/// Small tips on Home, one at a time, each shown once until the person closes it, and only when it
/// is relevant to what they have done so far. Every tip names something this build does.
enum HomeTip: String, CaseIterable, Identifiable {
    /// A dictation from today was not pasted: the shortcut gets it back.
    case pasteLast
    /// The main gesture, once the person has dictated at least once.
    case doubleTap
    case scratchThat
    case learnsFromFixes
    /// Until any app has a tone of its own.
    case appTone

    var id: String { rawValue }

    func title(triggerGlyph: String) -> String {
        switch self {
        case .pasteLast: "Paste it again with ⌃⌘V"
        case .doubleTap: "Double-tap \(triggerGlyph) for hands-free"
        case .scratchThat: "Say \u{201C}scratch that\u{201D}"
        case .learnsFromFixes: "Hushy learns when you fix a word"
        case .appTone: "Give an app its own tone"
        }
    }

    var line: String {
        switch self {
        case .pasteLast: "Your last dictation, in any app, even when it didn't land."
        case .doubleTap: "Talk as long as you like, then press Enter to paste."
        case .scratchThat: "Hushy drops what you said right before it."
        case .learnsFromFixes: "Correct it right after it lands, and it's spelled that way next time."
        case .appTone: "In Voice & style, move an app to the tone it should use."
        }
    }

    /// The tip's one way in, when it has one.
    var actionTitle: String? { self == .appTone ? "Open Voice & style" : nil }

    var symbol: String {
        switch self {
        case .pasteLast: "doc.on.clipboard"
        case .doubleTap: "hand.tap"
        case .scratchThat: "delete.backward"
        case .learnsFromFixes: "character.cursor.ibeam"
        case .appTone: "app.badge"
        }
    }
}

/// What the tips are chosen from. Counts and switches only, never dictated words.
struct HomeTipContext: Equatable {
    var dictationCount: Int
    /// A dictation made in the last day that Hushy could not paste.
    var hasRecentUnpasted: Bool
    var learnsFromEdits: Bool
    /// Some app already has a tone, kind or place of its own (`ToneSettings`).
    var hasAppTone: Bool
    var dismissed: Set<String>

    static let scratchThatAfter = 3
    static let learnsAfter = 5
    static let appToneAfter = 8

    /// The tip to show now, or nil. The order is by how much it helps right now: getting lost words
    /// back first, then the main gesture, then the ways to say less and fix less.
    var next: HomeTip? {
        HomeTip.allCases.first { !dismissed.contains($0.rawValue) && isRelevant($0) }
    }

    func isRelevant(_ tip: HomeTip) -> Bool {
        switch tip {
        case .pasteLast: hasRecentUnpasted
        case .doubleTap: dictationCount >= 1
        case .scratchThat: dictationCount >= Self.scratchThatAfter
        case .learnsFromFixes: learnsFromEdits && dictationCount >= Self.learnsAfter
        case .appTone: !hasAppTone && dictationCount >= Self.appToneAfter
        }
    }

    @MainActor
    static func make(dictations: [Dictation], settings: AppSettings, now: Date) -> HomeTipContext {
        let tones = settings.toneSettings
        let dayAgo = now.addingTimeInterval(-86_400)
        return HomeTipContext(
            dictationCount: dictations.count,
            hasRecentUnpasted: dictations.contains { $0.status == .notInserted && $0.createdAt >= dayAgo },
            learnsFromEdits: settings.learnFromEdits,
            hasAppTone: !tones.appChoices.isEmpty || !tones.appKinds.isEmpty || !tones.addedApps.isEmpty,
            dismissed: settings.dismissedHomeTips)
    }
}

/// One tip: a small icon, the tip in a few words, one line, an optional way in, and ✕.
struct HomeTipCard: View {
    let tip: HomeTip
    let triggerGlyph: String
    var onAction: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: tip.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.phosphor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.phosphorTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title(triggerGlyph: triggerGlyph))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(tip.line).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            if let action = tip.actionTitle {
                Button(action, action: onAction).buttonStyle(SecondaryButtonStyle())
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .help("Don't show this tip again")
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
        // Quieter than the feed's raised cards: a tip sits on the page, it is not content.
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tip: \(tip.title(triggerGlyph: triggerGlyph)). \(tip.line)")
    }
}
