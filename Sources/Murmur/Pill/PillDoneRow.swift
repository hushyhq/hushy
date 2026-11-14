import SwiftUI

/// Dictation's Done (design v3): a lime ✓, and beside it only what is worth saying: the word
/// count from 20 words up, "Pasted · quick cleanup only" when the model did not answer in time,
/// "as heard" when a check refused the rewrite, and "Pasted · Return not
/// pressed" when focus moved before the Return the person asked for. A short, clean paste is the
/// ✓ alone. When "Context awareness" changed this dictation, a small glyph says so — the only
/// visible trace of the feature running.
struct PillDoneRow: View {
    let words: Int
    let usedContext: Bool
    let asHeard: Bool
    let notSent: Bool
    var notARewrite = false

    var body: some View {
        HStack(spacing: 6) {
            CheckmarkDraw(tint: Theme.phosphorFill)
            if let line = PillModel.doneLine(words: words, asHeard: asHeard, notSent: notSent, notARewrite: notARewrite) {
                Text(line)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .help(PillModel.doneExplanation(asHeard: asHeard, notSent: notSent, notARewrite: notARewrite))
            }
            if usedContext {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.phosphorFill.opacity(0.85))
                    .help("Used text near your cursor for this dictation")
                    .accessibilityLabel("Used context from the screen")
            }
        }
        .fixedSize()
    }
}
