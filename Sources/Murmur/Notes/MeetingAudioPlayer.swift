import AVFoundation
import CryptoKit
import Foundation
import MurmurCore
import Observation

/// Plays a meeting from a moment, from the 30 s chunk files the recorder kept on this Mac (both
/// sides mixed when the call's audio was recorded). Granola keeps no audio; this is what lets every
/// row on the page be checked by ear. Reads only the chunks it plays, off the main thread.
@MainActor
@Observable
final class MeetingAudioPlayer {
    /// The note and moment playing now, so the row that asked can show a stop button.
    private(set) var playing: (noteId: Int64, seconds: Double)?
    private(set) var problem: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var offsets: [Int64: [ChunkSpan]] = [:]
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    /// How much is played from a moment: long enough to hear the point being made.
    nonisolated static let excerptSeconds: Double = 45

    struct ChunkSpan: Equatable {
        let micURL: URL
        let systemURL: URL?
        let start: Double
        let seconds: Double
        /// Journal rows, for a note recorded into the capture journal; nil for legacy chunk files.
        var micSegment: CaptureSegment?
        var systemSegment: CaptureSegment?
    }

    func isPlaying(noteId: Int64?, seconds: Double) -> Bool {
        guard let playing, let noteId else { return false }
        return playing.noteId == noteId && abs(playing.seconds - seconds) < 0.5
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        stopTask?.cancel()
    }

    func play(note: Note, from seconds: Double, key: SymmetricKey?, journal: CaptureJournal? = nil) {
        stop()
        problem = nil
        guard let id = note.id, let folder = note.audioPath.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            problem = "This meeting's audio isn't on this Mac."
            return
        }
        playing = (id, seconds)
        let cached = offsets[id]
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (spans: [ChunkSpan], data: Data?) in
                let spans = cached ?? journal.flatMap { Self.spans(journal: $0, folder: folder) } ?? Self.spans(in: folder, key: key)
                return (spans, Self.excerpt(spans: spans, from: seconds, key: key))
            }.value
            offsets[id] = result.spans
            guard playing?.noteId == id, playing?.seconds == seconds else { return }
            guard let data = result.data, let player = try? AVAudioPlayer(data: data) else {
                problem = "Couldn't play this part of the recording."
                playing = nil
                return
            }
            self.player = player
            player.play()
            let length = player.duration
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(length + 0.2))
                guard !Task.isCancelled else { return }
                self?.playing = nil
            }
        }
    }

    /// A journal's audio rows as spans on the note clock: each microphone segment (an imported file's segment) at its
    /// `t0`, with the call segment that starts closest to it. Nil when the journal holds no audio (a legacy note: its
    /// chunk files are read).
    nonisolated static func spans(journal: CaptureJournal, folder: URL) -> [ChunkSpan]? {
        let recorded = journal.audio(.mic).filter { $0.state != .open }
        let mic = recorded.isEmpty ? journal.audio(.file).filter { $0.state != .open } : recorded
        guard !mic.isEmpty else { return nil }
        let system = journal.audio(.system).filter { $0.state != .open }
        return mic.compactMap { segment in
            guard let file = segment.file else { return nil }
            let call = system.min { abs($0.t0 - segment.t0) < abs($1.t0 - segment.t0) }.flatMap { abs($0.t0 - segment.t0) < 1 ? $0 : nil }
            return ChunkSpan(
                micURL: folder.appendingPathComponent(file), systemURL: call?.file.map { folder.appendingPathComponent($0) },
                start: segment.t0, seconds: segment.duration, micSegment: segment, systemSegment: call)
        }
    }

    nonisolated private static func read(_ url: URL, segment: CaptureSegment?, key: SymmetricKey?) -> [Float]? {
        guard let segment else { return try? WAVWriter.read(url, key: key) }
        return try? CaptureSegmentAudio.samples(
            segment, folder: url.deletingLastPathComponent(), key: key, readLegacy: FinalizeRunner.readLegacy)
    }

    /// The chunk files in order with their start times, from each file's length.
    nonisolated static func spans(in folder: URL, key: SymmetricKey?) -> [ChunkSpan] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let mic = files.map { $0.lastPathComponent }
            .compactMap { name -> String? in
                let base = name.hasSuffix(".enc") ? String(name.dropLast(4)) : name
                return base.hasPrefix("chunk-") && base.hasSuffix(".wav") && !base.contains("-system") ? base : nil
            }
        var start = 0.0
        return Set(mic).sorted().compactMap { base in
            let url = folder.appendingPathComponent(base)
            guard let seconds = duration(of: url, key: key) else { return nil }
            let system = folder.appendingPathComponent(base.replacingOccurrences(of: ".wav", with: "-system.wav"))
            let hasSystem = FileManager.default.fileExists(atPath: system.path)
                || FileManager.default.fileExists(atPath: EncryptedFileStore.encryptedURL(for: system).path)
            defer { start += seconds }
            return ChunkSpan(micURL: url, systemURL: hasSystem ? system : nil, start: start, seconds: seconds)
        }
    }

    nonisolated static func duration(of url: URL, key: SymmetricKey?) -> Double? {
        if FileManager.default.fileExists(atPath: url.path), let file = try? AVAudioFile(forReading: url) {
            return Double(file.length) / AudioCapture.sampleRate
        }
        guard let samples = try? WAVWriter.read(url, key: key) else { return nil }
        return Double(samples.count) / AudioCapture.sampleRate
    }

    /// Up to `excerptSeconds` of audio from `seconds`, both sides summed, as WAV bytes.
    nonisolated static func excerpt(spans: [ChunkSpan], from seconds: Double, key: SymmetricKey?) -> Data? {
        guard let first = spans.lastIndex(where: { $0.start <= seconds }) ?? spans.indices.first else { return nil }
        var samples: [Float] = []
        let wanted = Int(excerptSeconds * AudioCapture.sampleRate)
        var skip = Int(max(0, seconds - spans[first].start) * AudioCapture.sampleRate)
        for span in spans[first...] where samples.count < wanted {
            guard var chunk = read(span.micURL, segment: span.micSegment, key: key) else { continue }
            if let systemURL = span.systemURL, let system = read(systemURL, segment: span.systemSegment, key: key) {
                for i in 0..<min(chunk.count, system.count) { chunk[i] = max(-1, min(1, chunk[i] + system[i])) }
                if system.count > chunk.count { chunk += system[chunk.count...] }
            }
            let from = min(skip, chunk.count)
            skip = 0
            samples += chunk[from...].prefix(wanted - samples.count)
        }
        return samples.isEmpty ? nil : HistoryPlaybackAudio.wavData(for: samples)
    }
}
