import SwiftUI

/// Keeps both columns only when each has enough room for its content. The divider is eight
/// points in History and half a point in Notes.
enum DetailLayout {
    enum Decision: Equatable {
        case split(listWidth: CGFloat, detailWidth: CGFloat)
        case listOnly
        case detailOnly
    }

    static func decide(
        available: CGFloat, preferredList: CGFloat, minimumList: CGFloat,
        minimumDetail: CGFloat, hasSelection: Bool, showSelectedDetail: Bool = true,
        dividerWidth: CGFloat = 8
    ) -> Decision {
        guard available >= minimumList + dividerWidth + minimumDetail else {
            return hasSelection && showSelectedDetail ? .detailOnly : .listOnly
        }
        let list = min(max(preferredList, minimumList), available - dividerWidth - minimumDetail)
        return .split(listWidth: list, detailWidth: available - dividerWidth - list)
    }
}

/// A compact detail returns to the list without clearing its selection. The leading Back
/// button is first in keyboard and VoiceOver order.
struct CompactDetail<Content: View>: View {
    let backTitle: String
    let onBack: () -> Void
    let content: Content

    init(backTitle: String, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.backTitle = backTitle
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.s)
            Divider().overlay(Theme.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CompactList<Content: View>: View {
    let onShowDetail: () -> Void
    let content: Content

    init(onShowDetail: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onShowDetail = onShowDetail
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Show selected details", action: onShowDetail)
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.s)
            Divider().overlay(Theme.hairline)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
