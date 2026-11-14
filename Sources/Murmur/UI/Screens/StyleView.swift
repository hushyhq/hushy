import MurmurCore
import SwiftUI

/// Style tab of Voice & style: the one place a person sets how Hushy writes (`WritingHome`). The board is the page
/// (`ToneBoardView`): every app, website and kind of app sits in the lane it is written in, As spoken included, and
/// moves by drag or from its menu. Below it only the two switches that also change the text (voice commands, American
/// spelling) and a note saying what does the polishing. Settings → Writing points here and repeats none of it.
struct StyleTabContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ToneBoardView()

            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        StyleSwitchRow(
                            symbol: "command", title: ToneCopy.voiceCommandsTitle, line: VoiceStyleCopy.voiceCommandsLine,
                            help: ToneCopy.voiceCommandsDetail, isOn: $settings.voiceCommands)
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 52)
                        StyleSwitchRow(
                            symbol: "character.textbox", title: ToneCopy.americanSpellingTitle,
                            line: VoiceStyleCopy.americanSpellingLine,
                            help: ToneCopy.americanSpellingDetail, isOn: $settings.americanSpelling)
                    }
                }
                // Status, not a choice: it sits outside the card, with no control of its own.
                PolishStatusNote()
            }
        }
    }
}

/// One switch under the tone board: a glyph, what it is called, a short sample of what it changes, and the switch.
/// The full sentence is hover help.
private struct StyleSwitchRow: View {
    let symbol: String
    let title: String
    let line: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.bgSunken))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(line).font(.system(size: 12, design: .serif)).italic().foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.l)
            SwitchToggle(isOn: $isOn).accessibilityLabel(title).accessibilityHint(help)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .help(help)
    }
}

/// Overlapping icons of installed apps in a category.
struct AppIconStack: View {
    let bundleIDs: [String]

    var body: some View {
        let installed = bundleIDs.filter { AppIcon.icon(for: $0) != nil }.prefix(5)
        HStack(spacing: -8) {
            ForEach(Array(installed), id: \.self) { id in
                AppIcon(bundleID: id)
                    .frame(width: 28, height: 28)
                    .padding(3)
                    .background(Circle().fill(Theme.bgRaised))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }
}
