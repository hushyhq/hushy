import MurmurCore
import SwiftUI

/// "Tune Hushy to your voice": name up to 5 terms, read 4 short sentences plus a silent
/// room-tone capture, then an auto-tune sweep picks the best {model, boosting} configuration
/// and shows a result card. Reachable from onboarding and re-runnable from Settings.
struct TuneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tune: TuneModel?
    var embedInOnboarding = false
    /// Called when the flow finishes (or is skipped). Defaults to the sheet's own `dismiss`;
    /// onboarding passes its own step-advance instead, since it embeds this view inline rather
    /// than presenting it as a sheet.
    var onFinished: (() -> Void)?

    var body: some View {
        Group {
            if let tune {
                TuneContent(tune: tune, embedInOnboarding: embedInOnboarding, onDone: onFinished ?? { dismiss() })
            } else {
                ProgressView().onAppear {
                    let created = TuneModel(
                        settings: model.settings, store: model.store,
                        voiceSignatureStore: model.encryption.voiceSignatureStore)
                    created.terms = Array((model.library.dictionary.prefix(5).map(\.term) + ["", "", "", "", ""]).prefix(5))
                    tune = created
                }
            }
        }
        .frame(width: 640, height: embedInOnboarding ? nil : 620)
    }
}

struct TuneContent: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Bindable var tune: TuneModel
    let embedInOnboarding: Bool
    let onDone: () -> Void
    /// Raw text of the comma-separated words field, kept separately so typing "Priya, "
    /// doesn't lose the comma when it's parsed into `tune.terms`.
    @State private var termsInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            switch tune.phase {
            case .namingTerms:
                namingTerms
            case .recording:
                if let sentence = tune.currentSentence {
                    VStack(spacing: Theme.Space.xxl) {
                        sentenceCard(sentence)
                        recordArea
                    }
                    .frame(maxHeight: .infinity)
                }
            case .roomTone:
                roomToneStep
            case .scoring:
                scoringStep
            case .result:
                resultStep
            case .failed(let message):
                EmptyState(symbol: "exclamationmark.triangle", title: "Tune couldn't finish", message: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bgBase)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Tune Hushy to your voice").font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                Text(TuneCopy.intro)
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !embedInOnboarding {
                IconButton(symbol: "xmark", help: "Close", action: onDone)
            }
        }
    }

    // MARK: Step 1 — naming terms

    private var namingTerms: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TuneStepRow(number: 1, text: TuneCopy.stepRead)
                TuneStepRow(number: 2, text: TuneCopy.stepRoom)
                TuneStepRow(number: 3, text: TuneCopy.stepShow)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    Text("Words Hushy gets wrong").font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                    Text("Optional").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Text(TuneCopy.termsHint)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isSnapshot {
                    SnapshotTextField(termsText, placeholder: "Priya, Kubernetes, Hushy")
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgRaised))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 1))
                } else {
                    TextField("Priya, Kubernetes, Hushy", text: $termsInput)
                        .onAppear { termsInput = termsText }
                        .onChange(of: termsInput) { _, text in setTerms(text) }
                        .textFieldStyle(.roundedBorder)
                        .help("Separate words with commas. Up to 5.")
                }
                Text("Separate with commas · up to 5")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Button("Start reading") { tune.startRecording() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var termsText: String {
        tune.terms.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// One comma-separated field instead of five identical boxes; keeps `terms` at 5 slots.
    private func setTerms(_ text: String) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kept = Array(parts.prefix(5))
        tune.terms = kept + Array(repeating: "", count: max(0, 5 - kept.count))
    }

    // MARK: Step 2 — sentences

    private func sentenceCard(_ sentence: TuneSentence) -> some View {
        Card(padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Eyebrow(sentence.isWhisper ? "Whisper" : "Say it naturally")
                    Spacer()
                    Text(tune.progressText).font(Theme.Font.data).foregroundStyle(Theme.textSecondary)
                }
                Text(sentence.text)
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordArea: some View {
        Group {
            if let pending = tune.pendingTake {
                reviewControls(pending)
            } else {
                VStack(spacing: Theme.Space.l) {
                    LevelMeter(level: tune.level, isActive: tune.isRecording)
                    RecordButton(isRecording: tune.isRecording) { tune.toggleRecording() }
                    Text(tune.isRecording ? "Recording — click to stop" : "Click to start, click again to stop")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func reviewControls(_ pending: TuneModel.PendingTake) -> some View {
        VStack(spacing: Theme.Space.l) {
            Card(padding: Theme.Space.l) {
                Text(String(format: "%.1fs · peak %.2f", Double(pending.samples.count) / 16_000, pending.peak))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.Space.m) {
                Button("Re-record") { tune.discardPendingTake() }.buttonStyle(SecondaryButtonStyle())
                Button("Keep") { tune.keepPendingTake() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 3 — room tone

    private var roomToneStep: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(Theme.phosphor)
            Text("Stay quiet for 2 seconds").font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
            Text(TuneCopy.roomTone)
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            if tune.isRecording {
                ProgressView().controlSize(.small)
            } else {
                Button("Start") { tune.captureRoomTone() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Step 4 — scoring

    private var scoringStep: some View {
        VStack(spacing: Theme.Space.l) {
            ProgressView(value: Double(tune.scoringProgress.done), total: Double(tune.scoringProgress.total))
                .frame(width: 240)
            Text("Trying \(tune.scoringProgress.done)/\(tune.scoringProgress.total) configurations…")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Result

    /// How many of the four sentences came back right, and that the run changed nothing.
    private var resultSummary: some View {
        let passed = tune.sentenceScores.filter(\.passed).count
        let allRight = passed == tune.sentenceScores.count
        return Card(padding: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(TuneCopy.resultHeadline(passed: passed, total: tune.sentenceScores.count),
                      systemImage: allRight ? "checkmark.seal.fill" : "waveform")
                    .font(Theme.Font.emphasis)
                    .foregroundStyle(allRight ? Theme.success : Theme.textPrimary)
                Text(TuneCopy.resultNote)
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// `ImageRenderer` can't draw `ScrollView` contents, so snapshots lay the result out directly.
    @ViewBuilder
    private var resultStep: some View {
        if isSnapshot {
            resultBody
        } else {
            ScrollView { resultBody }
        }
    }

    private var resultBody: some View {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if tune.winningCandidate != nil {
                    resultSummary
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Eyebrow("Per sentence")
                    ForEach(tune.sentenceScores) { score in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Image(systemName: score.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(score.passed ? Theme.success : Theme.error)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(score.sentence.text).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                                if !score.passed {
                                    Text("Heard: \(score.transcript)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                }

                if let calibration = tune.calibration, calibration.whisperBelowGateRisk {
                    Card(padding: Theme.Space.m) {
                        Label("Your whisper was close to your room's noise floor — try moving closer to the mic.", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                    }
                }

                // Voice signatures only label speakers in meeting notes (`FeatureFlags.meetings`).
                if FeatureFlags.meetings, Entitlements.has(.voiceSignatures) {
                    VoiceEnrollmentCard(tune: tune)
                }

                if !tune.mishearings.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Eyebrow("Words it still misheard")
                        FlowLayout(spacing: Theme.Space.s) {
                            ForEach(tune.mishearings) { mishearing in
                                MishearingChip(
                                    mishearing: mishearing,
                                    added: tune.addedDictionaryTerms.contains(mishearing.id),
                                    action: { tune.addToDictionary(mishearing) })
                            }
                        }
                    }
                }

                HStack(spacing: Theme.Space.m) {
                    Button("Open folder", action: tune.openFolder).buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button(embedInOnboarding ? "Continue" : "Done") { onDone() }.buttonStyle(PrimaryButtonStyle())
                }
            }
    }
}

private struct MishearingChip: View {
    let mishearing: TuneMishearing
    let added: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("\(mishearing.expectedWord) (heard “\(mishearing.heardWord)”)")
                    .font(Theme.Font.caption)
                if added {
                    Image(systemName: "checkmark")
                } else {
                    Image(systemName: "plus")
                }
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            .background(Capsule().fill(added ? Theme.success.opacity(0.15) : Theme.bgRaised))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(added)
        .foregroundStyle(added ? Theme.success : Theme.textPrimary)
    }
}

/// Voice-signature enrollment (free), shown on Tune's result step. Consent-first per this task's
/// requirement: the consent text (`VoiceEnrollmentConsent`) is always shown before the first
/// "Enroll my voice" tap, via a confirmation dialog — enrollment never runs just because Tune
/// finished.
private struct VoiceEnrollmentCard: View {
    @Bindable var tune: TuneModel
    @State private var showConsent = false

    var body: some View {
        Card(padding: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let voice = tune.enrolledVoice {
                    Label("Voice signature saved as “\(voice.name)”", systemImage: "checkmark.seal.fill")
                        .font(Theme.Font.emphasis).foregroundStyle(Theme.success)
                    Text("Future meeting notes can suggest “You” automatically. Manage or delete it anytime in Settings → Voices.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Label("Recognize your voice across notes", systemImage: "person.wave.2")
                        .font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                    Text("Hushy can remember what your voice sounds like from these recordings, so future meeting notes suggest \"You\" instead of \"Speaker 1.\"")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    if let error = tune.enrollmentError {
                        Text(error).font(Theme.Font.caption).foregroundStyle(Theme.error)
                    }
                    HStack {
                        Spacer()
                        if tune.isEnrolling {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Enroll my voice…") { showConsent = true }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
        .confirmationDialog(VoiceEnrollmentConsent.title, isPresented: $showConsent, titleVisibility: .visible) {
            Button("Enroll my voice") { tune.enrollYouVoice() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(VoiceEnrollmentConsent.body)
        }
    }
}

/// Live input level, matching `VoiceLabView`'s meter so the two recording flows feel identical.
private struct LevelMeter: View {
    let level: Float
    let isActive: Bool
    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule().fill(color(for: index)).frame(width: 6, height: height(for: index))
            }
        }
        .frame(height: 40)
        .animation(Theme.fade, value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let threshold = Float(index) / Float(barCount)
        let normalized = min(level * 6, 1)
        return normalized > threshold ? 10 + CGFloat(normalized) * 26 : 6
    }

    private func color(for index: Int) -> Color {
        guard isActive else { return Theme.hairline }
        let threshold = Float(index) / Float(barCount)
        let normalized = min(level * 6, 1)
        return normalized > threshold ? Theme.phosphor : Theme.hairline
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isRecording ? Theme.error : Theme.phosphorFill).frame(width: 64, height: 64)
                    .brightness(hovering ? -0.05 : 0)
                if isRecording {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.onPhosphor).frame(width: 20, height: 20)
                } else {
                    Circle().fill(Theme.onPhosphor).frame(width: 18, height: 18)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct TuneStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.onPhosphor)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.phosphorFill))
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
        }
    }
}
