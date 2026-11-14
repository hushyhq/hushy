import MurmurCore
import SwiftUI

/// The Today feed's one quiet line when Hushy started using words on its own:
/// "Learned from your edits: Priya, Kubernetes · Undo". No toast, no badge; Undo lives on the
/// line. Only exists once `FeatureFlags.autoActivateLearnedTerms` is on (the default since 2026-09-28): with the
/// flag off, nothing is ever used without the user's ✓, so there is nothing to announce.
struct LearnedNoticeLine: View {
    @Environment(AppModel.self) private var model
    let notice: LearnedReview.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: TimelineMetrics.gutterWidth, alignment: .leading)
                .padding(.leading, 5)
                .accessibilityHidden(true)
            line
            Spacer(minLength: 0)
        }
        .padding(.vertical, TimelineMetrics.rowVerticalPadding)
        .animation(Theme.Motion.pop, value: notice)
        .onAppear { model.learned.acknowledge(notice) }
        .onChange(of: notice) { _, newValue in model.learned.acknowledge(newValue) }
    }

    @ViewBuilder
    private var line: some View {
        if !notice.learned.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                (Text("Learned from your edits: ").foregroundStyle(Theme.textSecondary)
                    + Text(LearnedPresentation.names(notice.learned)).foregroundStyle(Theme.textPrimary).fontWeight(.medium))
                    .font(TimelineMetrics.titleFont)
                    .lineLimit(1)
                    .accessibilityLabel(LearnedPresentation.noticeText(notice.learned))
                Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                UndoLink(accessibilityText: "Undo, stop using \(LearnedPresentation.names(notice.learned))") {
                    model.learned.undoNotice(notice)
                }
            }
            .transition(.opacity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Stopped using \(LearnedPresentation.names(notice.forgotten))")
                    .font(TimelineMetrics.titleFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                UndoLink(accessibilityText: "Undo, keep using \(LearnedPresentation.names(notice.forgotten))") {
                    model.learned.redoNotice(notice)
                }
            }
            .transition(.opacity)
        }
    }
}
