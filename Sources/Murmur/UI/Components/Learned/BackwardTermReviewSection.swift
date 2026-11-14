import MurmurCore
import SwiftUI

/// Explicit, persistent decisions for historical terms that may have been learned backwards.
struct BackwardTermReviewSection: View {
    let library: Library

    var body: some View {
        if !library.backwardTermReviews.isEmpty {
            SettingsGroup {
                ForEach(library.backwardTermReviews) { item in
                    SettingsRow(title: "Review “\(item.value)”",
                                detail: "Heard as “\(item.heardAs.joined(separator: ", "))”, which is also one of your words. Keep this learned spelling?") {
                        HStack {
                            Button("Keep") { library.resolveBackwardTermReview(item, forget: false) }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("Forget") { library.resolveBackwardTermReview(item, forget: true) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }
}
