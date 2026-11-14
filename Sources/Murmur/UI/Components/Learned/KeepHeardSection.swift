import MurmurCore
import SwiftUI

/// Uses the same row treatment and Forget/Undo interaction as learned words.
struct KeepHeardSection: View {
    let library: Library
    @State private var review: KeepHeardReview

    init(library: Library) {
        self.library = library
        _review = State(initialValue: KeepHeardReview(
            forget: { [weak library] in library?.forgetKeepHeard($0) },
            restore: { [weak library] in library?.restoreKeepHeard($0) }))
    }

    var body: some View {
        let rows = review.rows(entries: library.keepHeardEntries)
        if !rows.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Eyebrow("Keep as heard")
                    Text("Changes you undid stay off in that app.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(rows) { row in
                        HStack(spacing: Theme.Space.m) {
                            let entry = row.entry
                            let app = LearnedAppName.name(for: entry.appBundleID, dictations: library.dictations)
                            AppBadge(bundleID: entry.appBundleID, appName: app)
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(row.forgotten ? "Forgot this exception" : "Keep “\(entry.heard)” in \(app)")
                                    .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                                if !row.forgotten {
                                    Text("Don't change it to “\(entry.written)”.")
                                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: Theme.Space.m)
                            if row.forgotten {
                                UndoLink(accessibilityText: "Undo forgetting this exception") { review.undo(row.id) }
                            } else {
                                UndoLink(title: "Forget", accessibilityText: "Forget the exception for \(entry.heard) in \(app)") {
                                    review.forget(entry)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
            }
        }
    }
}
