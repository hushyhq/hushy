import AVFoundation
import MurmurCore
import SwiftUI

/// The right-hand detail pane for one dictation — History's detail column, and (with `onClose`)
/// Home's slide-in inspector, so both screens show the exact same component. It always owns its
/// scroll view; the header reflows onto two lines when the pane is narrow instead of squashing.
struct HistoryDetailPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let dictation: Dictation
    /// Current search text, so matches can be highlighted in the transcript.
    var query: String = ""
    /// When set (Home's inspector), the header shows a close button.
    var onClose: (() -> Void)?
    @State private var copied = false
    @State private var copiedOriginal = false

    var body: some View {
        // `ImageRenderer` can't draw scroll view contents (see `ScreenLayout`), so snapshot
        // mode lays the same content out flat instead of in a real `ScrollView`.
        Group {
            if isSnapshot {
                content
            } else {
                ScrollView { content }
            }
        }
        .background(Theme.bgBase)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            Text(highlightedText)
                .font(.system(size: 15))
                .foregroundStyle(dictation.status == .cancelled || (dictation.status == .failed && dictation.text.isEmpty)
                                 ? Theme.textTertiary : Theme.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
            if let id = dictation.id {
                // "You corrected 'Pria' → 'Priya' twice. Add Priya?" Only for ready suggestions.
                LearnedSuggestionCard(dictationID: id)
            }
            if let path = dictation.audioPath {
                AudioStrip(path: path)
            }
            if dictation.rawText != dictation.text {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Eyebrow("You said")
                        Spacer()
                        LinkLikeButton(
                            title: copiedOriginal ? "Copied" : "Copy original",
                            font: .system(size: 11, weight: .semibold), action: copyOriginal)
                    }
                    WordDiffText(original: dictation.rawText, cleaned: dictation.text)
                }
            }
            if let outcome = dictation.cleanupOutcome.flatMap(CleanupOutcomeSummary.init(code:)) {
                Text(outcome.plainLine)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statsRow
            if let split = dictation.timeSplit {
                Text(split.plainLine(totalMs: dictation.latencyMs))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.xl)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// One line when there's room (History's wide column); otherwise identity + close on the
    /// first line and status + actions on the second (Home's narrower inspector).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                identity
                statusTag
                Spacer(minLength: Theme.Space.s)
                actions
                closeButton
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    identity
                    Spacer(minLength: Theme.Space.s)
                    closeButton
                }
                HStack(spacing: Theme.Space.s) {
                    statusTag
                    Spacer(minLength: Theme.Space.s)
                    actions
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: Theme.Space.s) {
            AppIcon(bundleID: dictation.appBundleID).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(dictation.appName ?? "Unknown app").font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(dictation.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if let path = dictation.audioPath { PlayButton(path: path) }
            if canRetry {
                RetryButton(isRetrying: isRetrying) { model.retryDictationTranscription(dictation) }
            } else if !dictation.text.isEmpty {
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button("Delete", role: .destructive) {
                withAnimation(Theme.fade) { model.library.deleteDictation(dictation) }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .fixedSize()
    }

    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            IconButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
                .accessibilityLabel("Close details")
        }
    }

    @ViewBuilder
    private var statusTag: some View {
        switch dictation.status {
        case .cancelled:
            HistoryTag(text: "Cancelled", color: Theme.textTertiary)
            if DictationRecovery.action(for: dictation) == .copy {
                LinkLikeButton(title: "Recover", font: .system(size: 11, weight: .semibold)) { model.library.recover(dictation) }
            }
        case .failed:
            HistoryTag(text: dictation.audioPath == nil ? "Transcription failed" : "Audio saved · transcription failed", color: Theme.error)
        case .notInserted:
            HistoryTag(text: "Not pasted", color: Theme.warning)
        case .inserted:
            if dictation.rawText != dictation.text {
                HistoryTag(text: "Cleaned", color: Theme.phosphor)
            } else {
                HistoryTag(text: "Kept as typed", color: Theme.textSecondary)
            }
        }
    }

    /// All metrics on one line when they fit, else a two-row grid — never clipped.
    private var statsRow: some View {
        let metrics = self.metrics
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                ForEach(metrics, id: \.label) { HistoryMetric(label: $0.label, value: $0.value) }
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
                ForEach(Array(stride(from: 0, to: metrics.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(metrics[start..<min(start + 3, metrics.count)], id: \.label) {
                            HistoryMetric(label: $0.label, value: $0.value)
                        }
                    }
                }
            }
        }
    }

    private var metrics: [(label: String, value: String)] {
        var result: [(label: String, value: String)] = [
            ("Spoken", Duration.seconds(dictation.durationSeconds).formatted(.time(pattern: .minuteSecond))),
            ("Words", "\(dictation.wordCount)"),
            ("Speed", "\(Int(dictation.wordsPerMinute)) wpm"),
        ]
        if let time = Self.timeMetric(for: dictation) { result.append(time) }
        if dictation.fixes > 0 { result.append(("Changed", dictation.fixes == 1 ? "1 word" : "\(dictation.fixes) words")) }
        return result
    }

    /// "Typed in" (or "Processed in") with the time in seconds, nil when the dictation has no time.
    static func timeMetric(for dictation: Dictation) -> (label: String, value: String)? {
        guard dictation.latencyMs > 0 else { return nil }
        return (dictation.status == .inserted ? "Typed in" : "Processed in", DictationTimeSplit.seconds(dictation.latencyMs))
    }

    private var canRetry: Bool { DictationRecovery.action(for: dictation) == .retryTranscription }

    private var isRetrying: Bool { model.dictation.retryingDictationID == dictation.id }

    private var displayText: String {
        if dictation.status == .cancelled { return dictation.rawText.isEmpty ? "Cancelled recording" : dictation.rawText }
        if dictation.status == .failed && dictation.text.isEmpty {
            if !dictation.rawText.isEmpty { return "Couldn't prepare text. Original transcript: \(dictation.rawText)" }
            return dictation.audioPath == nil ? "Transcription failed. No audio was retained." : "Transcription failed. Play the saved audio to recover what you said."
        }
        if dictation.status == .inserted && dictation.text.isEmpty { return "Pressed Return (no text to type)" }
        return dictation.text
    }

    /// The transcript with the current search term highlighted, matching the list's
    /// "highlights matches in list + detail" requirement.
    private var highlightedText: AttributedString {
        var result = AttributedString(displayText)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let range = result[searchRange].range(of: trimmed, options: .caseInsensitive) {
            result[range].backgroundColor = Theme.phosphorFill.opacity(0.35)
            searchRange = range.upperBound..<result.endIndex
        }
        return result
    }

    private func copy() {
        TextInserter.copy(dictation.text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func copyOriginal() {
        TextInserter.copy(dictation.rawText)
        copiedOriginal = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copiedOriginal = false
        }
    }
}

/// Detail pane for a stacked run of identical failures: one line per recording with its own
/// recovery actions, since a stack can mix "audio saved" and "no audio" outcomes. Ports the
/// old inline `StackedFailureDetail` content to the full-page detail pane.
struct StackedFailureDetailPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let items: [Dictation]

    var body: some View {
        Group {
            if isSnapshot {
                content
            } else {
                ScrollView { content }
            }
        }
        .background(Theme.bgBase)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                HistoryTag(text: "\(items.count) failed", color: Theme.error)
                Text("Transcription failed for each of these recordings.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(items) { item in
                    HStack(spacing: Theme.Space.s) {
                        Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(Theme.Font.data).foregroundStyle(Theme.textTertiary)
                        Text(item.audioPath == nil ? "No audio was retained" : "Audio saved")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        if let path = item.audioPath {
                            PlayButton(path: path)
                            RetryButton(isRetrying: model.dictation.retryingDictationID == item.id) {
                                model.retryDictationTranscription(item)
                            }
                        }
                        Button("Delete") {
                            withAnimation(Theme.settle) { model.library.deleteDictation(item) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(Theme.Space.s)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
                }
            }
            Button("Delete all \(items.count)", role: .destructive) {
                withAnimation(Theme.settle) { model.library.deleteDictations(items) }
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: Theme.Space.xl)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.Font.data).foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct HistoryTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
