import MurmurCore
import SwiftUI

/// A memo's text on its page, with "How do you want it?" above it (founder, 2026-11-07; spec in the 2026-11-07 UI
/// review §0.4). Refined is the note as written, drawn by the page itself (`asWritten`, with its play chips); the other
/// styles are versions kept beside the note. While a version is written the old text stays in place, blurred under a
/// label, so the box keeps its size; the new text then fades in. Under Reduce Motion there is no blur, only a fade.
struct NoteRestyleSection<AsWritten: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    let note: Note
    @ViewBuilder var asWritten: AsWritten

    private var styles: NoteRestyleModel { model.noteStyles }
    private var page: NoteRestyleModel.Page { styles.page(for: note) }

    private var rewriting: RestyleStyle? {
        if case .rewriting(let style) = page.phase { return style }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text(NoteRestyleCopy.controlLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                NoteStylePicker(selected: rewriting ?? page.state.style) { style in
                    styles.pick(style, for: note)
                }
            }
            statusLine
            text
        }
        .onAppear { styles.load(note) }
        .onChange(of: note.transcript) { _, _ in styles.load(note) }
    }

    // MARK: The text

    private var text: some View {
        let covered = rewriting != nil
        return ZStack(alignment: .top) {
            Group {
                if page.state.style == .refined {
                    asWritten
                } else {
                    Text(page.state.text(body: note.transcript))
                        .font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .id(page.state.style)
            .transition(.opacity)
            .blur(radius: covered && !reduceMotion ? 6 : 0)
            .opacity(covered ? 0.5 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            if let style = rewriting {
                RewritingLabel(style: style) { styles.stop(note) }
                    .padding(.top, Theme.Space.l)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.32, dampingFraction: 0.88), value: covered)
        .animation(Theme.Motion.fade, value: page.state.style)
    }

    // MARK: Which style, and the way back

    @ViewBuilder
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Group {
                if case .notice(let line) = page.phase {
                    Label(line, systemImage: "checkmark.shield").foregroundStyle(Theme.textSecondary)
                } else {
                    Text(NoteRestyleCopy.shownAs(page.state.style)
                         + (page.state.style == .refined ? "" : " · " + NoteRestyleCopy.originalKept))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.Font.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if page.state.canUndo, rewriting == nil {
                LinkLikeButton(title: NoteRestyleCopy.undo) { styles.undo(note) }.fixedSize()
            }
            if page.state.style != .refined, rewriting == nil {
                LinkLikeButton(title: NoteRestyleCopy.backToRefined) { styles.pick(.refined, for: note) }.fixedSize()
            }
        }
    }
}

/// The glass label over the covered text: what is happening, that it yields to dictation, and how to stop it.
private struct RewritingLabel: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let style: RestyleStyle
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if isSnapshot {
                Circle().trim(from: 0, to: 0.7).stroke(Theme.working, lineWidth: 1.5).frame(width: 10, height: 10)
            } else {
                ProgressView().controlSize(.mini).tint(Theme.working)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(NoteRestyleCopy.rewriting).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(NoteRestyleCopy.rewritingDetail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Button(NoteRestyleCopy.stop, action: stop)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised.opacity(isSnapshot ? 0.85 : 0.4)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NoteRestyleCopy.rewriting) \(NoteRestyleCopy.style(style))")
    }
}

/// Refined · Professional · Casual. Equal widths, one sunken track, the chosen segment raised; the plate moves
/// between segments (UI review §0.4: 28 pt tall, radii 8 and 6, padding 2).
private struct NoteStylePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var plate
    let selected: RestyleStyle
    let pick: (RestyleStyle) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NoteRestyle.styles, id: \.self) { style in
                Button { pick(style) } label: {
                    Text(NoteRestyleCopy.style(style))
                        .font(.system(size: 13, weight: style == selected ? .semibold : .medium))
                        .foregroundStyle(style == selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if style == selected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.bgRaised)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "plate", in: plate)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(style == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 28)
        .frame(maxWidth: 540)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bgSunken))
        .animation(Theme.Motion.spatial(Theme.snappy, reduceMotion: reduceMotion), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NoteRestyleCopy.controlLabel)
    }
}
