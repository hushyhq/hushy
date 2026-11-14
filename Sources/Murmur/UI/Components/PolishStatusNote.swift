import MurmurCore
import SwiftUI

/// What the status note says: the sentence for whatever polishes dictation right now
/// (`CleanupModelController.activeBackendDescription`, never reworded here), and whether to add
/// that tones still apply. Worked out apart from the view so a test can read it.
struct PolishStatus: Equatable {
    /// The rule beside the note: the model's colour while a model polishes, the warning colour
    /// when none can and a tone is chosen, and a quiet grey when none can and none is needed.
    enum Mark: Equatable { case model, reduced, quiet }

    let sentence: String
    let mark: Mark

    init(sentence: String, isModelAvailable: Bool, isAsSpoken: Bool) {
        self.sentence = sentence
        mark = isModelAvailable ? .model : (isAsSpoken ? .quiet : .reduced)
    }

    /// Nothing can polish while a tone is chosen: the simpler fixes run and tones still apply.
    var isReduced: Bool { mark == .reduced }

    /// The whole note as VoiceOver reads it.
    var spokenLabel: String {
        "\(ToneCopy.polishStatusTitle). \(sentence)" + (isReduced ? " \(ToneCopy.tonesStillApply)" : "")
    }
}

/// "What polishes your text": status, not a choice. It has no control and no raised surface, so it
/// reads as a note beside the choices it describes (Voice & style → Style, Settings → Writing).
struct PolishStatusNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = PolishStatus(
            sentence: model.cleanupModel.activeBackendDescription,
            isModelAvailable: model.cleanupModel.isModelAvailable,
            isAsSpoken: model.settings.toneSettings.isAsSpoken)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Eyebrow(ToneCopy.polishStatusTitle)
            Text(status.sentence).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.isReduced {
                Text(ToneCopy.tonesStillApply).font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(.leading, Theme.Space.m)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(tint(for: status.mark)).frame(width: 2)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spokenLabel)
    }

    private func tint(for mark: PolishStatus.Mark) -> Color {
        switch mark {
        case .model: Theme.working
        case .reduced: Theme.warning
        case .quiet: Theme.textTertiary
        }
    }
}
