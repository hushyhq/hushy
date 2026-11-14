import MurmurCore
import SwiftUI

/// The format editor: name and icon, cleanup level, instruction, and a live preview of what the format does to a
/// fixed sample sentence. A stored app assignment from before Formats is kept and honoured; it shows here as one quiet
/// line with a way to stop it, and nowhere else.
struct FormatEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.colorScheme) private var scheme
    @State private var draft: Mode
    @State private var preview: String = ""
    @State private var isPreviewing = false
    let onSave: (Mode) -> Void

    init(mode: Mode, onSave: @escaping (Mode) -> Void) {
        _draft = State(initialValue: mode)
        self.onSave = onSave
    }

    private static let icons = [
        "waveform", "envelope", "message", "note.text", "list.bullet", "sparkles", "briefcase",
        "checkmark.circle", "text.quote", "megaphone", "person.2", "doc.text",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                iconPicker
                nameField
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Cleanup")
                if isSnapshot {
                    SnapshotSegmentedLook(titles: CleanupLevel.allCases.map(\.title), selected: draft.cleanupLevel.title)
                } else {
                    Picker("", selection: $draft.cleanupLevel) {
                        ForEach(CleanupLevel.allCases) { level in Text(level.title).tag(level) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(VoiceStyleCopy.instructionTitle).help(VoiceStyleCopy.instructionHelp)
                instructionField
            }

            previewBlock

            if !draft.appBundleIDs.isEmpty { automaticLine }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.bgRaised)
        .task(id: "\(draft.cleanupLevel.rawValue)|\(draft.prompt ?? "")") {
            guard !isSnapshot else { return }
            await runPreview()
        }
    }

    private var iconPicker: some View {
        let face = Image(systemName: draft.icon)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.phosphor)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.phosphorTint))
        return Group {
            if isSnapshot {
                face
            } else {
                Menu {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button { draft.icon = icon } label: { Label(icon, systemImage: icon) }
                    }
                } label: { face }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Icon")
                .accessibilityLabel("Icon")
            }
        }
    }

    @ViewBuilder private var nameField: some View {
        if isSnapshot {
            Text(draft.name).font(.system(size: 22, design: .serif)).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(VoiceStyleCopy.formatNameField, text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, design: .serif))
                .accessibilityLabel(VoiceStyleCopy.formatNameField)
        }
    }

    @ViewBuilder private var instructionField: some View {
        let text = Binding(get: { draft.prompt ?? "" }, set: { draft.prompt = $0 })
        Group {
            if isSnapshot {
                Text(text.wrappedValue.isEmpty ? VoiceStyleCopy.instructionPlaceholder : text.wrappedValue)
                    .font(Theme.Font.body)
                    .foregroundStyle(text.wrappedValue.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            } else {
                TextEditor(text: text)
                    .font(Theme.Font.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 52)
                    .overlay(alignment: .topLeading) {
                        if text.wrappedValue.isEmpty {
                            Text(VoiceStyleCopy.instructionPlaceholder).font(Theme.Font.body)
                                .foregroundStyle(Theme.textTertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(VoiceStyleCopy.instructionTitle)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well(scheme)))
    }

    /// The sample, what was said, above what this format makes of it, the same two halves as a tone's example.
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(VoiceStyleCopy.previewTitle)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("“\(VoiceStyleCopy.previewSample)”")
                    .font(.system(size: 12, design: .serif)).italic().foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if isPreviewing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(preview.isEmpty ? VoiceStyleCopy.previewSample : preview)
                            .font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 9).padding(.leading, 12).padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well(scheme)))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.phosphor).frame(width: 2).padding(.vertical, 8)
                }
            }
        }
    }

    private var automaticLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "app.badge").font(.system(size: 10, weight: .semibold))
            Text(VoiceStyleCopy.alsoAutomatic(draft.appBundleIDs.count))
            LinkLikeButton(title: VoiceStyleCopy.stopAutomatic) { draft.appBundleIDs = [] }
        }
        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        .help(draft.appBundleIDs.joined(separator: ", "))
    }

    /// Runs the exact production path (`DictationPipeline.clean` with `strategy: .rules` for the
    /// cleanup stage, then `ModeExecutor` for the transform) so the preview can never drift from
    /// what a real dictation does. `.rules` keeps the cleanup half deterministic in the editor;
    /// the transform itself still calls the real on-device model when available, which is
    /// the whole point of a live preview.
    private func runPreview() async {
        isPreviewing = true
        defer { isPreviewing = false }
        let pipeline = DictationPipeline(transcriber: NullTranscriber())
        let cleanupOptions = CleanupOptions(level: draft.cleanupLevel, voiceCommandsEnabled: true)
        let settings = PipelineSettings(cleanupOptions: cleanupOptions, mode: draft)
        let result = await pipeline.clean(VoiceStyleCopy.previewSample, settings: settings, strategy: .rules)
        preview = result.text
    }
}

/// A transcriber that is never called (the editor preview always calls `pipeline.clean(_:...)`
/// with pre-transcribed text), needed only to satisfy `DictationPipeline`'s initializer.
private struct NullTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}
