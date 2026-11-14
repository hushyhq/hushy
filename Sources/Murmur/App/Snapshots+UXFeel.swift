import MurmurCore
import SwiftUI

/// Stills for the ux-feel round (2026-10-28). `HUSHY_SNAPSHOT_ONLY=uxf-` renders just these.
///
/// - `uxf-paste-glow`: the paste glow as three moments of its 600 ms (in, peak, fading), drawn with
///   the live ring's own numbers (`PasteGlowStyle`, `PasteGlowTiming`) around an invented field.
///   The live glow is a click-through AppKit window that `ImageRenderer` cannot capture; this
///   still shows its look, not its timing.
/// - `uxf-pill-presence-*`: Settings → General's Mini / Large / Hidden choice.
/// - `uxf-home-tip-*`: each Home tip card (Home's own pages show whichever one the fixtures earn).
extension Snapshots {
    static func renderUXFeel(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        await capture(PasteGlowStill(), name: "uxf-paste-glow", scheme: scheme,
                      size: CGSize(width: 1080, height: 140), directory: directory, fixedSize: true)
        // Each Home tip on its own, at Home's content width.
        for tip in HomeTip.allCases {
            await capture(
                HomeTipCard(tip: tip, triggerGlyph: "fn", onDismiss: {}).padding(Theme.Space.xl),
                name: "uxf-home-tip-\(tip.rawValue)", scheme: scheme, size: CGSize(width: 900, height: 110),
                directory: directory, fixedSize: true)
        }
        // Settings → General's pill choice, in each selection, and Large in Low Power Mode.
        await capture(
            SettingsGroup {
                SettingsRow(title: "Launch at login", detail: "So the dictation key is always ready.") {
                    SwitchToggle(isOn: .constant(true))
                }
                PillPresencePicker(selection: .constant(.mini), isLowPower: false)
                SettingsRow(title: GeneralSettingsPane.hidePillTitle, detail: GeneralSettingsPane.hidePillDetail) {
                    SwitchToggle(isOn: .constant(true))
                }
                SettingsRow(title: "Sounds", detail: "Quiet ticks when listening starts and stops.", showsDivider: false) {
                    SwitchToggle(isOn: .constant(false))
                }
            }
            .padding(Theme.Space.xl),
            name: "uxf-hide-pill-during-video", scheme: scheme, size: CGSize(width: 780, height: 420),
            directory: directory, fixedSize: true)
        for (name, presence, lowPower) in [
            ("mini", PillPresence.mini, false), ("large", .large, false), ("hidden", .hidden, false), ("large-lowpower", .large, true),
        ] {
            await capture(
                SettingsGroup { PillPresencePicker(selection: .constant(presence), isLowPower: lowPower) }
                    .padding(Theme.Space.xl),
                name: "uxf-pill-presence-\(name)", scheme: scheme, size: CGSize(width: 780, height: 230),
                directory: directory, fixedSize: true)
        }
    }
}

/// An invented message field in an invented app, with the ring at three moments.
private struct PasteGlowStill: View {
    @Environment(\.colorScheme) private var scheme

    private let moments: [(label: String, opacity: Double, halo: CGFloat)] = [
        ("\(Int(PasteGlowTiming.fadeIn * 1000)) ms · in", 1, PasteGlowStyle.haloStart),
        ("\(Int((PasteGlowTiming.fadeIn + PasteGlowTiming.hold) * 1000)) ms · held", 1, 8),
        ("\(Int((PasteGlowTiming.fadeIn + PasteGlowTiming.hold + PasteGlowTiming.fadeOut * 0.6) * 1000)) ms · fading", 0.35, PasteGlowStyle.haloPeak),
    ]

    private var accent: Color {
        scheme == .dark ? Color(hex: 0x8B97FF) : Color(hex: 0x4A5AE6)
    }

    var body: some View {
        HStack(spacing: Theme.Space.xl) {
            ForEach(moments, id: \.label) { moment in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    field
                        .overlay {
                            let radius = PasteGlowGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 300, height: 40))
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(accent.opacity(Double(scheme == .dark ? PasteGlowStyle.fillAlphaDark : PasteGlowStyle.fillAlphaLight)))
                                .shadow(color: accent.opacity(Double(PasteGlowStyle.haloOpacity)), radius: moment.halo)
                                .padding(-PasteGlowGeometry.outset / 2)
                                .opacity(moment.opacity)
                        }
                    Text(moment.label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var field: some View {
        Text("Let's meet at nine and bring your laptop.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 300, height: 40, alignment: .leading)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
