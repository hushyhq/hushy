import MurmurCore
import SwiftUI

/// Left-hand stepper: labeled groups, the current one highlighted, completed ones checked. The
/// model keeps downloading in the background across every step, so its progress lives here too,
/// pinned to the bottom, rather than blocking any one step. When pacing inserted "while it
/// downloads" steps, they appear as their own group between Permissions and Try it.
struct OnboardingStepper: View {
    let flow: OnboardingFlow
    let downloads: DownloadCoordinator
    let modelSizeText: String

    private struct StepGroup {
        let title: String
        let detail: String
        let steps: [OnboardingStep]
        let tracksModel: Bool
    }

    private var groups: [StepGroup] {
        var groups = [
            StepGroup(title: "Download model", detail: modelSizeText, steps: [.welcome, .invite], tracksModel: true),
            StepGroup(title: "Permissions", detail: "Microphone, Accessibility", steps: [.microphone, .accessibility], tracksModel: false),
            StepGroup(title: "Your key", detail: "Double-tap to talk", steps: [.hotkeyPractice], tracksModel: false),
        ]
        let optional = flow.plannedOptional
        if !optional.isEmpty {
            let place = optional.firstIndex(of: flow.current).map { "\($0 + 1) of \(optional.count)" } ?? "\(optional.count) short steps"
            groups.append(StepGroup(
                title: "While it downloads", detail: "Optional · \(place)", steps: optional, tracksModel: false))
        }
        groups.append(StepGroup(title: "Try it now", detail: "Your first dictation", steps: [.tryIt, .done], tracksModel: false))
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.bottom, Theme.Space.xxl)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    StepperRow(number: index + 1, title: group.title, detail: group.detail, state: state(of: group))
                }
            }
            Spacer()
            ModelDownloadFooter(downloads: downloads)
        }
    }

    private var currentGroupIndex: Int {
        groups.firstIndex { $0.steps.contains(flow.current) } ?? 0
    }

    /// The download row reflects the model's real state, not the page the user is on: it is only
    /// ticked once the model is ready, and stays "current" while it downloads in the background.
    private func state(of group: StepGroup) -> RowState {
        if group.tracksModel { return downloads.status.isReady ? .done : .current }
        guard let index = groups.firstIndex(where: { $0.title == group.title }) else { return .upcoming }
        return index < currentGroupIndex ? .done : (index == currentGroupIndex ? .current : .upcoming)
    }

    private enum RowState { case done, current, upcoming }

    private struct StepperRow: View {
        let number: Int
        let title: String
        let detail: String
        let state: RowState

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(state == .current ? Theme.phosphorFill : (state == .done ? Theme.phosphorTint : Theme.bgSunken))
                        .frame(width: 22, height: 22)
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.phosphor)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(state == .current ? Theme.onPhosphor : Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                        .foregroundStyle(state == .upcoming ? Theme.textTertiary : Theme.textPrimary)
                    Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// Bottom-left model download progress, visible on every step. One honest line —
/// "Speech model · 312 of ~632 MB · about 1 min" — over an ink bar (a download is background
/// work, not something live the user must attend to, so it doesn't glow; see Afterglow §1).
/// Paused on a metered network, it asks; offline, it says it will resume by itself.
struct ModelDownloadFooter: View {
    let downloads: DownloadCoordinator

    private var status: SpeechModelStatus { downloads.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(symbolTint)
                }
                Text(headline).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if downloads.needsMeteredConsent {
                MeteredNetworkPrompt(downloads: downloads, compact: true)
            } else if let download = status.download, !status.isReady {
                DownloadBar(fraction: download.fraction, isActive: status.isDownloadingPrimary)
                if let remaining = download.estimatedSecondsRemaining, status.isDownloadingPrimary {
                    Text("about \(ModelDownloadProgress.formatRemaining(remaining)) left")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
                // Offline pauses resume by themselves; only a real failure gets a button.
                if let failure = status.failure, !failure.isOffline { retry }
            } else if status.isReady {
                Capsule().fill(Theme.success).frame(height: 4)
            } else if let failure = status.failure, !failure.isOffline {
                retry
            } else {
                // Indeterminate (listing files, or loading once downloaded): a spinner reads more
                // honestly than a bar frozen at 0%, which `ImageRenderer` can't draw anyway.
                ProgressView().controlSize(.small).tint(Theme.textSecondary)
            }
        }
        .animation(Theme.Motion.fade, value: downloads.needsMeteredConsent)
    }

    private var retry: some View {
        Button("Retry download") {
            downloads.retryNow()
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var headline: String {
        if downloads.needsMeteredConsent { return "Paused · metered network" }
        if downloads.waitingForUnmetered { return "Speech model · waiting for Wi-Fi" }
        switch status.state {
        case .ready, .downloadingVocabulary: return "Speech model ready"
        case .downloading:
            return status.download.map { bytesLine($0) } ?? "Speech model · starting"
        case .paused:
            let bytes = status.download.map { " · " + ModelDownloadProgress.formatBytes($0.estimatedBytes) + " kept" } ?? ""
            return "Paused · offline\(bytes)"
        case .loading: return "Preparing speech model…"
        case .failed:
            return status.failure?.isOffline == true ? "Offline · resumes by itself" : "Speech model download failed"
        case .idle: return downloads.waitingForNetwork ? "Offline · resumes by itself" : "Speech model · starting"
        }
    }

    /// "Speech model · 312 of ~632 MB" — the time part sits on its own line under the bar.
    private func bytesLine(_ download: ModelDownloadProgress) -> String {
        ModelDownloadProgress(fraction: download.fraction, expectedBytes: download.expectedBytes)
            .compactLine(title: "Speech model")
    }

    private var symbol: String? {
        if downloads.needsMeteredConsent || downloads.waitingForUnmetered { return "antenna.radiowaves.left.and.right" }
        if status.failure?.isOffline == true || status.state == .paused || downloads.waitingForNetwork { return "wifi.slash" }
        if status.failure != nil { return "exclamationmark.triangle.fill" }
        return nil
    }

    private var symbolTint: Color {
        status.failure != nil && status.failure?.isOffline == false ? Theme.warning : Theme.textSecondary
    }
}

/// "You're on a metered network": the one question the download ever asks. Waiting for the
/// user's answer, so it's the one place here that may glow (the primary button).
struct MeteredNetworkPrompt: View {
    let downloads: DownloadCoordinator
    var compact = false

    private var sizeText: String {
        ModelDownloadProgress.formatBytes(max(downloads.queue.requiredRemainingBytes, 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(compact
                 ? "About \(sizeText) left to download. Personal Hotspot or Low Data Mode may cost data."
                 : "You're on Personal Hotspot or Low Data Mode. The speech model is a one-time download of about \(sizeText) — download it now, or Hushy waits for Wi-Fi and continues by itself.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Download now") { downloads.approveMeteredDownload() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Wait for Wi-Fi") { downloads.deferUntilUnmetered() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// A determinate bar drawn with shapes: `ProgressView(value:)` is an AppKit control that
/// `ImageRenderer` can't draw in snapshot mode. Ink, not lime; the fill eases between byte
/// counts so it never jumps.
struct DownloadBar: View {
    let fraction: Double
    var isActive = true
    var accessibilityTitle = "Speech model download"

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bgSunken)
                Capsule().fill(isActive ? Theme.textSecondary : Theme.textTertiary)
                    .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.9), value: fraction)
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Under the practice box on "Try it": what stands between the user and their first dictation,
/// if anything. Ready → a nudge; seconds away → "ready in about 20 s".
struct ModelReadiness: View {
    let downloads: DownloadCoordinator

    var body: some View {
        let status = downloads.status
        HStack(spacing: Theme.Space.s) {
            if status.isReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("Ready — keep the box focused while you talk.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else if let download = status.download, status.isDownloadingPrimary {
                Image(systemName: "arrow.down.circle").foregroundStyle(Theme.textSecondary)
                Text(download.estimatedSecondsRemaining.map { "Almost there — ready in about \(ModelDownloadProgress.formatRemaining($0))." }
                     ?? "Almost there — \(download.compactLine(title: "speech model")).")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "hourglass").foregroundStyle(Theme.textSecondary)
                Text("Preparing the speech model — a few seconds.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// "Try it" when the model is minutes away, offline, or waiting on a metered network: no
/// practice box to stare at. Says exactly what is happening and lets the user finish; one
/// notification arrives when the model is ready.
struct TryItWaiting: View {
    let variant: TryItVariant
    let downloads: DownloadCoordinator
    let triggerGlyph: String
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(Theme.Font.section)
            Text(message)
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if case .waiting(.meteredNetwork) = variant {
                MeteredNetworkPrompt(downloads: downloads)
            } else if let download = downloads.status.download {
                VStack(alignment: .leading, spacing: 6) {
                    DownloadBar(fraction: download.fraction, isActive: downloads.status.isDownloadingPrimary)
                        .frame(maxWidth: 360)
                    // Bytes only: the time left is already in the sentence above.
                    Text(ModelDownloadProgress(fraction: download.fraction, expectedBytes: download.expectedBytes)
                        .compactLine(title: "Speech model"))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 6) {
                Text(OnboardingCopy.tryItWaitingLead).foregroundStyle(Theme.textSecondary)
                KeyCap(label: triggerGlyph)
                Text(OnboardingCopy.tryItWaitingTail).foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.Font.body)
            HStack(spacing: Theme.Space.s) {
                Button("Finish setup", action: onFinish)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                if case .waiting(let reason) = variant, reason != .meteredNetwork {
                    Button("Try again now") { downloads.retryNow() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var minutesText: String {
        guard case .stillDownloading(let seconds) = variant else { return "" }
        return ModelDownloadProgress.formatRemaining(seconds)
    }

    private var title: String {
        switch variant {
        case .waiting(.offline): "You're offline"
        case .waiting(.meteredNetwork): "Download on this network?"
        case .waiting(.failed): "The download stopped"
        default: "Almost set"
        }
    }

    private var message: String {
        switch variant {
        case .stillDownloading:
            "Your speech model is still downloading (\(minutesText) left). We'll let you know when it's ready — you can finish setup and close this window."
        case .waiting(.offline):
            "Your speech model is a one-time download, and it continues by itself when you're back online. We'll let you know when it's ready."
        case .waiting(.meteredNetwork):
            "Hushy paused its speech model download so it doesn't use your data allowance."
        case .waiting(.failed):
            "\(downloads.status.failure?.message ?? "Something went wrong.") Hushy retries by itself; we'll let you know when the model is ready."
        default:
            "Your speech model is still downloading. We'll let you know when it's ready."
        }
    }
}
