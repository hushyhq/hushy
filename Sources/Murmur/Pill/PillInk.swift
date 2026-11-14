import SwiftUI

/// The processing pill's text: the stage label ("Hearing", "Applying Email…") until words exist,
/// then the words themselves as ink — *wet* (dim, slightly soft) while cleanup runs, *dry*
/// (crisp white) once the cleaned text is final (docs/design/DESIGN-LANGUAGE.md §3.1).
///
/// Wet ink always sits behind a "Polishing" label (2026-09-27): on its own, dim text next to the
/// waveform read as the finished result, so a slow cleanup looked like a paste that was stuck.
/// The label says the words are a preview and work is still happening; it leaves with the wet ink.
///
/// No layout shift: the slot has a fixed maximum width, keeps one line, and truncates at the
/// head behind a leading fade, so a longer sentence never pushes the pill wider than the cap and
/// the newest words — the ones the user just said — are the ones visible.
struct PillInkLabel: View {
    let stage: PillModel.ProcessingStage
    let ink: PillModel.Ink?
    /// A transform mode's name ("Email"), which labels the wait instead of wet ink.
    let modeName: String?
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion

    static let maxWidth: CGFloat = 240
    /// Room the "Polishing" label takes from the ink, so the pill is no wider while wet.
    static let labelReserve: CGFloat = 62

    var body: some View {
        ZStack(alignment: .leading) {
            if let ink {
                HStack(spacing: 6) {
                    if Self.showsPolishingLabel(for: ink) {
                        stageText(PillModel.ProcessingStage.polishing.label)
                            .transition(.opacity)
                    }
                    inkText(ink)
                }
                .animation(motion.animation(.fade), value: ink.isDry)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)))
            } else {
                stageText(labelText)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .animation(motion.animation(.fade), value: ink == nil)
        .animation(motion.animation(.fade), value: labelText)
    }

    /// Wet ink is a preview while cleanup runs, so it always carries the "Polishing" label; dry
    /// ink is the final text and stands alone.
    static func showsPolishingLabel(for ink: PillModel.Ink?) -> Bool {
        ink.map { !$0.isDry } ?? false
    }

    private var labelText: String {
        if let modeName, stage != .typing { return "Applying \(modeName)…" }
        return stage.label
    }

    private func stageText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.pillWorking)
            .lineLimit(1)
            .fixedSize()
    }

    private func inkText(_ ink: PillModel.Ink) -> some View {
        let width = ink.isDry ? Self.maxWidth : Self.maxWidth - Self.labelReserve
        return inkBody(ink, width: width)
    }

    private func inkBody(_ ink: PillModel.Ink, width: CGFloat) -> some View {
        // Short text shows whole; only text that overflows the slot gets the head truncation and
        // the leading fade, so a short phrase never has its first letters dimmed.
        ViewThatFits(in: .horizontal) {
            styled(ink).fixedSize()
            // Overflow: pin the text's *end* to the slot's trailing edge and let the start run
            // out under a fade — no "…", just ink disappearing into the left, like a tape head.
            styled(ink).fixedSize()
                .frame(width: width, alignment: .trailing)
                .clipped()
                .mask(leadingFade)
        }
        .frame(maxWidth: width, alignment: .leading)
        // Drying is the afterglow decay in reverse: wet → dry along the cool curve.
        .animation(motion.animation(.cool, reduceMotion: reduceMotion), value: ink.isDry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ink.isDry ? "Typing: \(ink.text)" : "Polishing. Heard: \(ink.text)")
    }

    private func styled(_ ink: PillModel.Ink) -> some View {
        Text(ink.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.isDry ? Color.white.opacity(0.95) : Theme.inkWet)
            .blur(radius: ink.isDry || reduceMotion ? 0 : 0.35)
            .lineLimit(1)
            .contentTransition(.opacity)
    }

    private var leadingFade: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }
}
