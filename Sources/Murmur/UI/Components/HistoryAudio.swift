import AppKit
import AVFoundation
import CryptoKit
import MurmurCore
import Observation
import SwiftUI

/// Shared audio, waveform, app-icon and diff-rendering components used by both History's
/// detail pane and Home's recent rows. Was previously split across the old `HistoryTimeline`
/// (the inline, expandable Home timeline this replaces); the timeline view itself is gone; this
/// file keeps only the pieces still shared across screens.

/// The original transcript with the words cleanup removed struck through.
struct WordDiffText: View {
    let original: String
    let cleaned: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        let originalWords = WordDiff.words(original)
        let kept = WordDiff.keptFlags(original: original, cleaned: cleaned)
        var result = AttributedString()
        for (index, word) in originalWords.enumerated() {
            var piece = AttributedString(word)
            if index < kept.count, !kept[index] {
                piece.strikethroughStyle = .single
                piece.foregroundColor = Theme.error.opacity(0.8)
            } else {
                piece.foregroundColor = Theme.textSecondary
            }
            result += piece
            // The space stays unstruck, so a removed word doesn't drag a line into the next one.
            if index < originalWords.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

/// Re-runs transcription on saved audio for a row that has none. Shows a spinner while busy
/// instead of disappearing, so the user knows the tap landed.
struct RetryButton: View {
    let isRetrying: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(Circle().fill(hovering ? Theme.selection : .clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
        .help("Retry transcription")
        .accessibilityLabel("Retry transcription")
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

// MARK: - Audio

/// One shared player: starting a clip stops the previous one, and every row reflects it.
@MainActor
@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    /// Resolves the decryption key for an encrypted audio file, or nil to treat every file as
    /// plaintext. Set once by `AppModel` at launch (`EncryptionController.currentKey`). Kept as
    /// a settable closure rather than a direct `EncryptionController` reference so this file
    /// doesn't need to import it, and so Voice Lab (which never encrypts) can leave it alone —
    /// `EncryptedFileStore`/`WAVWriter` fall back to plaintext for any file that isn't actually
    /// encrypted regardless of what this returns.
    nonisolated(unsafe) static var resolveKey: () -> SymmetricKey? = { nil }

    private(set) var currentPath: String?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// A seek asked for while the clip was still being prepared; applied once it is ready.
    @ObservationIgnored private var pendingSeek: Double?

    func toggle(_ path: String) {
        if currentPath == path, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        if currentPath == path, loadTask != nil { return }
        stop()
        currentPath = path
        // Preparing the lifted playback copy (see `HistoryPlaybackAudio`) reads and normalises
        // the whole file, so it runs off the main thread; the player appears once it is ready.
        let key = Self.resolveKey()
        loadTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                try? HistoryPlaybackAudio.prepare(path: path, key: key)
            }.value
            guard !Task.isCancelled, let self, self.currentPath == path else { return }
            self.loadTask = nil
            // Fall back to the raw saved audio if the lifted copy could not be built.
            guard let player = data.flatMap({ try? AVAudioPlayer(data: $0) }) ?? Self.makePlayer(forPath: path) else {
                self.stop()
                return
            }
            self.player = player
            if let fraction = self.pendingSeek {
                player.currentTime = player.duration * min(max(fraction, 0), 1)
                self.progress = fraction
                self.pendingSeek = nil
            }
            self.resume()
        }
    }

    /// Builds a player for a path that may be a legacy plaintext WAV or (`.wav.enc`, detected by
    /// magic header, not extension) an encrypted one. A file that is encrypted but whose key
    /// can't be obtained (`resolveKey` returns nil — encryption is off, or the Keychain item is
    /// unavailable) simply fails to play rather than risk feeding garbage bytes to `AVAudioPlayer`.
    private static func makePlayer(forPath path: String) -> AVAudioPlayer? {
        let url = URL(fileURLWithPath: path)
        let encryptedURL = EncryptedFileStore.encryptedURL(for: url)
        let sourceURL = FileManager.default.fileExists(atPath: encryptedURL.path) ? encryptedURL : url
        guard EncryptedFileStore.isEncrypted(at: sourceURL) else {
            return try? AVAudioPlayer(contentsOf: url)
        }
        guard let key = resolveKey(), let data = try? EncryptedFileStore.read(sourceURL, key: key) else { return nil }
        return try? AVAudioPlayer(data: data)
    }

    func seek(_ path: String, to fraction: Double) {
        if currentPath != path { toggle(path) }
        guard let player else {
            if currentPath == path { pendingSeek = fraction }
            return
        }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
        progress = fraction
    }

    private func resume() {
        player?.play()
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
    }

    private func stop() {
        loadTask?.cancel()
        loadTask = nil
        pendingSeek = nil
        player?.stop()
        player = nil
        ticker?.invalidate()
        isPlaying = false
        progress = 0
        currentPath = nil
    }

    private func tick() {
        guard let player else { return }
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        if !player.isPlaying {
            // Finished: reset so the next press plays from the start.
            isPlaying = false
            progress = 0
            ticker?.invalidate()
            player.currentTime = 0
        }
    }

    func isActive(_ path: String) -> Bool { currentPath == path }
}

/// Play/pause with a progress ring, so it is always clear what is playing.
struct PlayButton: View {
    let path: String
    @State private var player = AudioPlayer.shared
    @State private var hovering = false

    var body: some View {
        let active = player.isActive(path)
        Button { player.toggle(path) } label: {
            ZStack {
                Circle().fill(hovering || active ? Theme.selection : .clear)
                if active {
                    Circle().trim(from: 0, to: player.progress)
                        .stroke(Theme.phosphor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                }
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(active ? Theme.phosphor : Theme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active && player.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")
        .onHover { hovering = $0 }
    }
}

/// A waveform of the recording that fills as it plays; click anywhere to seek.
struct AudioStrip: View {
    let path: String
    @State private var player = AudioPlayer.shared
    @State private var peaks: [Float] = []

    var body: some View {
        let active = player.isActive(path)
        HStack(spacing: Theme.Space.m) {
            PlayButton(path: path)
            GeometryReader { geometry in
                // Bars are laid out to the available width (not a fixed 90 × 4.5 pt), so the
                // strip never overflows a narrow container like Home's inspector pane.
                let progress = active ? player.progress : 0
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = size.width / CGFloat(peaks.count)
                    let barWidth = min(2.5, max(1, step * 0.55))
                    for (index, peak) in peaks.enumerated() {
                        let height = max(3, CGFloat(peak) * 26)
                        let rect = CGRect(
                            x: CGFloat(index) * step + (step - barWidth) / 2,
                            y: (size.height - height) / 2, width: barWidth, height: height)
                        let played = Double(index) / Double(peaks.count) < progress
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                     with: .color(played ? Theme.phosphor : Theme.textTertiary.opacity(0.5)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    player.seek(path, to: location.x / geometry.size.width)
                }
            }
            .frame(height: 28)
        }
        .padding(Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
        .task(id: path) { peaks = await Waveforms.peaks(for: path, count: 90) }
    }
}

/// Downsampled amplitude envelopes of saved recordings, cached per file.
@MainActor
enum Waveforms {
    private static var cache: [String: [Float]] = [:]

    static func peaks(for path: String, count: Int) async -> [Float] {
        if let cached = cache[path] { return cached }
        let key = AudioPlayer.resolveKey()
        let result = await Task.detached(priority: .utility) { () -> [Float] in
            guard let samples = try? WAVWriter.read(URL(fileURLWithPath: path), key: key), !samples.isEmpty else { return [] }
            let bucket = max(samples.count / count, 1)
            let raw = stride(from: 0, to: samples.count, by: bucket).map { start -> Float in
                let slice = samples[start..<min(start + bucket, samples.count)]
                return slice.reduce(0) { max($0, abs($1)) }
            }
            let top = raw.max() ?? 1
            return raw.map { top > 0 ? $0 / top : 0 }
        }.value
        cache[path] = result
        return result
    }
}

/// The icon of the app a dictation went into.
struct AppIcon: View {
    let bundleID: String?

    /// A dictation made in Hushy itself (the onboarding practice field, or any future in-app
    /// text entry) has no foreign app to show an icon for; `NSWorkspace` can't resolve our own
    /// bundle ID to an on-disk `.app` reliably in every build config (dev builds, DEBUG runs
    /// outside `/Applications`), so this is asked for explicitly instead of relying on the
    /// generic lookup path resolving it by chance. Falls back to a mic glyph — never the dashed
    /// "unknown app" placeholder, which reads as broken rather than "recorded here".
    private var isOwnApp: Bool {
        guard let bundleID else { return false }
        return MurmurCore.Insights.ownBundleIDs.contains(bundleID)
    }

    var body: some View {
        Group {
            if isOwnApp {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "mic.fill").foregroundStyle(Theme.phosphor)
                }
            } else if let image = Self.icon(for: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityHidden(true)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}
