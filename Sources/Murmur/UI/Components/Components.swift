import MurmurCore
import SwiftUI

/// Raised surface. In dark mode, depth comes from contrast (hairline border, no shadow) as
/// before. In light mode, depth comes from a soft shadow plus a low-contrast hairline, so
/// cards lift off the paper background instead of reading as a stark white box with a border.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: scheme == .dark ? .clear : Theme.cardShadow.opacity(Theme.cardShadowOpacity),
                    radius: 12, y: 3)
    }
}

/// Small expanded-width uppercase label above a group.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.eyebrow)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Screen title in the editorial serif with an optional subtitle.
struct ScreenHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    // Wraps rather than truncates: a page introduction cut off with "…" hides
                    // the sentence that explains the page.
                    Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            accessory
        }
    }
}

extension ScreenHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A big number with a label, used across Home and Insights.
struct Stat: View {
    let value: String
    let label: String
    var accent: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .regular, design: .serif).monospacedDigit())
                .foregroundStyle(accent)
                .contentTransition(.numericText())
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Primary call to action: phosphor fill, dark text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onPhosphor)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(
                Capsule().fill(Theme.phosphorFill)
                    .brightness(configuration.isPressed ? -0.08 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Quiet secondary button: hairline capsule.
struct SecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering || configuration.isPressed ? Theme.selection : .clear))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .onHover { hovering = $0 }
            .animation(Theme.fade, value: hovering)
    }
}

/// Icon-only button that reveals a tinted circle on hover.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.selection : .clear))
                // The whole circle takes the click and the hover, not only the glyph.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    /// Optional recovery action (e.g. "Clear filter" when a filter produced zero results).
    /// Defaults to `nil` so every existing call site is unaffected.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(.system(size: 20, design: .serif)).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
                // Wraps to as many lines as it needs; a short window must not cut guidance off.
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.section)
    }
}

/// A status dot with a label ("Model ready", "Hotkey active").
struct StatusDot: View {
    let color: Color
    let label: String
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 4).scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 0.8))
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Static look-alike of a segmented `Picker`, for snapshot mode: `ImageRenderer` can't draw
/// the AppKit-backed `.segmented` style, so this shows the same pill row without interaction.
struct SnapshotSegmentedLook: View {
    let titles: [String]
    let selected: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 12, weight: title == selected ? .semibold : .regular))
                    .foregroundStyle(title == selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control - 2)
                            .fill(title == selected ? Theme.bgRaised : .clear))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
    }
}

/// Monospaced, selectable code block with a copy button.
struct CodeBlock: View {
    let code: String
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // ImageRenderer can't draw ScrollView contents, so snapshot mode lays the code
            // out flat instead of in a horizontally scrolling strip.
            if isSnapshot {
                Text(code)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(Theme.Space.m)
                    .padding(.trailing, 60)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.m)
                        .padding(.trailing, 60)
                }
            }
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(Theme.Space.s)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
    }
}

/// Shared pill-shaped search field used by History and Notes' own inline search (distinct
/// from the ⌘K `SearchPalette`, which searches both at once from anywhere in the app).
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            if isSnapshot {
                SnapshotTextField(text, placeholder: prompt)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($focused)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.bgRaised))
        .overlay(Capsule().strokeBorder(focused ? Theme.phosphor.opacity(0.6) : Theme.hairline, lineWidth: 1))
        .animation(Theme.fade, value: focused)
    }
}

extension View {
    /// Standard screen padding and scroll container.
    func screen() -> some View {
        modifier(ScreenLayout())
    }
}

/// Standard page padding inside a scroll view. Snapshot rendering can't draw scroll view
/// contents, so in snapshot mode the page is laid out flat at its full height instead.
private struct ScreenLayout: ViewModifier {
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let page = content
            .padding(.horizontal, Theme.Space.xxl + 8)
            .padding(.top, Theme.Space.xxl + 8)
            .padding(.bottom, Theme.Space.section)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        if isSnapshot {
            page.frame(maxHeight: .infinity, alignment: .top).background(Theme.bgBase)
        } else {
            ScrollView { page }
                .scrollContentBackground(.hidden)
                .background(Theme.bgBase)
        }
    }
}

extension EnvironmentValues {
    @Entry var isSnapshot = false
    /// Snapshot-only: forces `HistoryView`'s filter, so both segments can be captured.
    @Entry var snapshotHistoryFilter: HistoryPageFilter?
    /// Snapshot-only: pre-selects a row and enters Select mode in `HistoryView`, so the
    /// multi-select action bar can be captured without a live click sequence.
    @Entry var snapshotHistorySelecting = false
    /// Snapshot-only: forces `HistoryView`'s date filter, so the active-filter chip and its
    /// combined-with-search/status behavior can be captured without a live popover interaction.
    @Entry var snapshotHistoryDateRange: HistoryDateRange?
    /// Snapshot-only: highlights the feed's first dictation (as when its Quick Look is open), so
    /// the selected-row state can be captured without a live click.
    @Entry var snapshotHomeSelection = false
    /// Snapshot-only: forces the pill's ✕/✓ hover tooltips to render without a live hover, so
    /// `--snapshots` can capture "Cancel" / "Done" etc.
    @Entry var snapshotForceTooltip = false
    /// Snapshot mode: force only the pill hint with exactly this text.
    @Entry var snapshotTooltipText: String? = nil
    /// Snapshot-only: pins whether the sidebar and the Account pane render a founding member, so
    /// the real account on this Mac can't change what `--snapshots` captures.
    @Entry var snapshotPlan: SnapshotPlan?
    @Entry var snapshotProAccount: ProPageSnapshotAccount?
    /// Snapshot-only: forces the sidebar's `SidebarReadinessRow` into its Keyboard-settings-conflict
    /// warning state. That state depends on reading the real machine's Globe-key action and
    /// macOS Dictation shortcut (`Permissions.globeKeyAction`/`macDictationClashes`), which
    /// `--snapshots` can't control — this bypasses both so the warning capture is deterministic.
    @Entry var snapshotDictateWarning = false
    /// Snapshot-only: show Home's usage-numbers notice.
    @Entry var snapshotUsageNotice = false
    /// Snapshot-only: pre-selects this dictation in `HistoryView`, so the detail pane (and the
    /// learned-term suggestion card in it) can be captured without a live click.
    @Entry var snapshotHistoryDetailID: Int64?
    /// Snapshot-only: opens Voice & style on this tab.
    @Entry var snapshotVoiceStyleTab: VoiceAndStyleView.Tab?
    /// Which apps are installed; the system by default, a fixed set in snapshots.
    @Entry var installedApps: any InstalledApps = SystemInstalledApps()
    /// Words dictated per app, for ordering apps in the tone screens; snapshots set it, otherwise it is read locally.
    @Entry var snapshotAppUsage: [String: Int]?
    /// Snapshot-only: renders the sidebar's alternative lower-band layout (`SidebarLayout`).
    @Entry var snapshotSidebarLayout: SidebarLayout?
    /// Snapshot-only: shows the voice-actions key row as if macOS Dictation also listened for it.
    @Entry var snapshotActionTriggerClash: Bool?
    /// Snapshot-only: shows the voice-action practice (Settings → Voice actions) at this phase.
    @Entry var snapshotActionRehearsal: VoiceActionRehearsal.Phase?
    /// Snapshot-only: shows the Apple Notes toggles after this outcome. In snapshot mode the
    /// toggles never call the exporter, so no AppleScript runs and no Automation prompt appears.
    @Entry var snapshotAppleNotesResult: AppleNotesAccessResult?
}

/// See `EnvironmentValues.snapshotPlan`. Hushy is free (founder, 2026-11-11); the only difference
/// between accounts is the founding-member badge.
enum SnapshotPlan: Equatable {
    case free, founding

    var isFoundingMember: Bool { self == .founding }
}

/// An account fixture for the Account pane; no persistent account state is read while rendering.
struct ProPageSnapshotAccount {
    let signedIn: Bool
    let session: AccountSession?
    let inviteOutcome: BetaInviteOutcome?
    let configuration: AccountConfiguration
}

/// A label-less `.switch` toggle that `--snapshots` can draw. `ImageRenderer` renders the
/// AppKit-backed switch as a yellow "no" glyph, which made every Settings snapshot look
/// broken; in snapshot mode this draws a static look-alike in the same footprint instead.
struct SwitchToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            SnapshotSwitchLook(isOn: isOn)
        } else {
            // A real AppKit switch. (This once called `SwitchToggle` itself, which recursed
            // forever the moment a live window drew any switch.)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Static look-alike of a macOS switch (26×15, the regular control size) for snapshot mode.
struct SnapshotSwitchLook: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.phosphor : Theme.textTertiary.opacity(0.35))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
            .accessibilityLabel(isOn ? "On" : "Off")
    }
}

/// `ImageRenderer` can't draw `.buttonStyle(.link)` either — like text fields, it's backed by
/// an AppKit control and renders as the same yellow "no" glyph. In snapshot mode this shows
/// the label as plain phosphor-colored text instead, matching the link style's look at rest.
struct LinkLikeButton: View {
    let title: String
    var font: Font = Theme.Font.caption
    let action: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Text(title).font(font).foregroundStyle(Theme.phosphor)
        } else {
            Button(title, action: action).buttonStyle(.link).font(font)
        }
    }
}

/// `ImageRenderer` can't draw `TextField`/`TextEditor` — they're backed by `NSTextView`/
/// `NSTextField` and come out as a yellow bar with a "no" glyph. In snapshot mode, views swap
/// their real text field for this static look-alike so search boxes and inputs render faithfully.
struct SnapshotTextField: View {
    let text: String
    let isPlaceholder: Bool
    var font: Font = Theme.Font.body

    init(_ text: String, placeholder: String, font: Font = Theme.Font.body) {
        self.font = font
        if text.isEmpty {
            self.text = placeholder
            self.isPlaceholder = true
        } else {
            self.text = text
            self.isPlaceholder = false
        }
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(isPlaceholder ? Theme.textTertiary : Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }
}
