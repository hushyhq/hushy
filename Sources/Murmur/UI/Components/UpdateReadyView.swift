import AppKit
import SwiftUI

/// The small, calm card shown when an update has been downloaded: relaunch now, or later (it then
/// installs when Hushy quits). "What's new" opens the release notes inside the card, or the notes
/// page when that is all the update carries.
struct UpdateReadyView: View {
    static let width: CGFloat = 340

    let prompt: UpdateReadyPrompt
    var startsExpanded = false
    var onRelaunch: () -> Void
    var onLater: () -> Void
    var onExpandedChange: (Bool) -> Void = { _ in }
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var expanded = false
    @State private var notesHeight: CGFloat = 0
    private static let notesMaxHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(UpdateCopy.readyTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(UpdateCopy.readyDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded, case .text(let notes) = prompt.notes {
                notesBody(notes)
            }
            HStack(spacing: Theme.Space.s) {
                notesButton
                Spacer(minLength: Theme.Space.s)
                Button(UpdateCopy.later, action: onLater).buttonStyle(SecondaryButtonStyle())
                Button(UpdateCopy.relaunchNow, action: onRelaunch)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.hairline, lineWidth: 1))
        .onAppear { expanded = startsExpanded }
    }

    /// As tall as the notes, up to a maximum, then scrolls. `ImageRenderer` cannot draw a scroll
    /// view, so snapshots clip at the same maximum instead.
    @ViewBuilder private func notesBody(_ notes: String) -> some View {
        let text = Text(UpdateReleaseNotes.attributed(notes))
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if isSnapshot {
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: Self.notesMaxHeight, alignment: .top).clipped()
        } else {
            ScrollView {
                text.textSelection(.enabled)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { notesHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in notesHeight = height }
                    })
            }
            .frame(height: notesHeight > 0 ? min(notesHeight, Self.notesMaxHeight) : Self.notesMaxHeight)
        }
    }

    @ViewBuilder private var notesButton: some View {
        switch prompt.notes {
        case .none:
            EmptyView()
        case .text:
            Button(expanded ? UpdateCopy.hideWhatsNew : UpdateCopy.whatsNew) {
                expanded.toggle()
                onExpandedChange(expanded)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
        case .link(let url):
            Button(UpdateCopy.whatsNew) { openLink(url) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
