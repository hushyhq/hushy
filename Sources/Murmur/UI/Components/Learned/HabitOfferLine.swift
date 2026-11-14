import MurmurCore
import SwiftUI

/// "In Slack you leave out greetings. Should Hushy do the same there? · Use · No thanks", asked once per habit.
struct HabitOfferLine: View {
    @Environment(AppModel.self) private var model
    let row: LearnedReview.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: TimelineMetrics.gutterWidth, alignment: .leading)
                .padding(.leading, 5)
                .accessibilityHidden(true)
            line
            Spacer(minLength: 0)
        }
        .padding(.vertical, TimelineMetrics.rowVerticalPadding)
        .animation(Theme.Motion.pop, value: row)
        .onAppear { model.learned.markOffered(row.item) }
        .onChange(of: row) { _, newValue in model.learned.markOffered(newValue.item) }
    }

    private var question: String {
        let app = LearnedAppName.name(for: row.item.appBundleID, dictations: model.library.dictations)
        return LearnedPresentation.habitQuestion(row.item, appName: app) ?? LearnedPresentation.addedLine(row.item)
    }

    @ViewBuilder
    private var line: some View {
        switch row.outcome {
        case nil:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(question)
                    .font(TimelineMetrics.titleFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                ConfirmVerbButton(verb: "Use", accessibilityText: "Use this habit in this app") {
                    model.learned.add(row.item, from: .offer)
                }
                UndoLink(title: "No thanks", accessibilityText: "Don't suggest this habit again") {
                    model.learned.dismiss(row.item, from: .offer)
                }
            }
            .transition(.opacity)
        case let outcome?:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(outcome == .added ? LearnedPresentation.addedLine(row.item) : LearnedPresentation.dismissedLine(row.item))
                    .font(TimelineMetrics.titleFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                UndoLink(accessibilityText: "Undo for this habit") { model.learned.undo(row.id) }
            }
            .transition(.opacity)
        }
    }
}
