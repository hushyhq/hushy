import SwiftUI

/// The multi-line box both feedback sheets use. An image render cannot draw a `TextEditor`, so a
/// snapshot draws the text as plain text in the same place.
struct FeedbackMessageBox: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Binding var message: String
    var placeholder: String
    var isDisabled = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSnapshot {
                Text(message).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 5).padding(.vertical, 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $message).font(Theme.Font.body).scrollContentBackground(.hidden)
                    .disabled(isDisabled)
                    .accessibilityLabel(placeholder)
            }
            if message.isEmpty {
                Text(placeholder).font(Theme.Font.body).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 5).allowsHitTesting(false)
            }
        }
        .padding(Theme.Space.s)
        .frame(height: 140)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.hairline))
    }
}
