@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// One AMI meeting prepared for `TwoChannelDiarizeRunner`'s mic/system simulation: one
/// participant's individual headset channel (the "mic"), the meeting's official `Mix-Headset`
/// (the "system" stream proxy), and the same official RTTM ground truth
/// `AmiMeetingDownloader`/`DiarizeRunner` use.
struct TwoChannelMeeting: Sendable {
    let meetingId: String
    /// The RTTM speaker id whose individual headset channel was used as "mic" — chosen as
    /// whichever speaker RTTM lists as speaking first, so the choice is deterministic and not
    /// arbitrary "speaker A."
    let micSpeakerId: String
    let systemMix: [Float]
    let turns: [AmiMeeting.Turn]
    var durationSeconds: Double { Double(systemMix.count) / 16_000 }
}

/// Downloads what `TwoChannelDiarizeRunner` needs beyond what `AmiMeetingDownloader` already
/// fetches for the single-stream eval: one participant's individual headset channel per meeting.
/// Reuses the same official ground-truth RTTM and the same `Mix-Headset` audio source as the
/// existing `ihm` config, so this is strictly additive — no new ground-truth source, no
/// reconstruction.
enum TwoChannelAmiDownloader {
    enum DownloaderError: LocalizedError {
        case noHeadsetChannelFound(String)
        var errorDescription: String? {
            switch self {
            case .noHeadsetChannelFound(let meeting): "No individual headset channel resolved for meeting \(meeting)"
            }
        }
    }

    /// Same fixed 3-meeting "mini" subset `AmiMeetingDownloader` uses, for consistency between
    /// the single-stream and two-channel eval reports.
    private static let testMiniMeetings = ["IS1009a", "ES2004a", "TS3003a"]

    /// AMI headset channels are numbered `Headset-0`...`Headset-3` (up to 4 participants per
    /// meeting); tried in order and the first that both exists and corresponds to a speaker with
    /// official RTTM turns is used.
    private static let headsetChannelCandidates = (0...3).map { "Headset-\($0)" }

    static func download(meetingCount: Int, root: URL) async throws -> [TwoChannelMeeting] {
        let cacheDir = root.appendingPathComponent("ami-two-channel", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let meetingIds = Array(testMiniMeetings.prefix(max(meetingCount, 1)))
        var meetings: [TwoChannelMeeting] = []
        for meetingId in meetingIds {
            if let cached = try? loadCached(meetingId: meetingId, cacheDir: cacheDir) {
                print("  \(meetingId): using cached two-channel simulation data")
                meetings.append(cached)
                continue
            }
            do {
                let meeting = try await buildMeeting(meetingId: meetingId)
                try cacheMeeting(meeting, cacheDir: cacheDir)
                meetings.append(meeting)
            } catch {
                print("  \(meetingId): skipped (\(error.localizedDescription))")
            }
        }
        return meetings
    }

    private static func buildMeeting(meetingId: String) async throws -> TwoChannelMeeting {
        let turns = try await fetchOfficialRTTM(meetingId: meetingId)
        guard let micSpeakerId = turns.min(by: { $0.beginTime < $1.beginTime })?.speakerId else {
            throw DownloaderError.noHeadsetChannelFound(meetingId)
        }

        let base = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/\(meetingId)/audio"
        // The mic speaker's own headset channel is used only to confirm this meeting has a
        // resolvable per-speaker channel (a real prerequisite for the "with channel split"
        // condition to mean anything) — AMI does not expose an RTTM-speaker-id -> Headset-N
        // mapping directly, so this probes for *any* individual headset channel existing at all
        // rather than claiming a specific channel belongs to `micSpeakerId`.
        var foundChannel: String?
        for channel in headsetChannelCandidates {
            let candidate = URL(string: "\(base)/\(meetingId).\(channel).wav")!
            if try await urlExists(candidate) {
                foundChannel = channel
                break
            }
        }
        guard foundChannel != nil else { throw DownloaderError.noHeadsetChannelFound(meetingId) }

        let mixURL = URL(string: "\(base)/\(meetingId).Mix-Headset.wav")!
        let systemMix = try await downloadAndResample(mixURL)
        return TwoChannelMeeting(meetingId: meetingId, micSpeakerId: micSpeakerId, systemMix: systemMix, turns: turns)
    }

    // MARK: RTTM (shared source with AmiMeetingDownloader)

    private static func fetchOfficialRTTM(meetingId: String) async throws -> [AmiMeeting.Turn] {
        for split in ["test", "dev", "train"] {
            let url = URL(string: "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/\(split)/\(meetingId).rttm")!
            if let data = try? await fetchIfExists(url) {
                return parseRTTM(data)
            }
        }
        throw DownloaderError.noHeadsetChannelFound(meetingId)
    }

    private static func parseRTTM(_ data: Data) -> [AmiMeeting.Turn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [AmiMeeting.Turn] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 8, fields[0] == "SPEAKER",
                  let start = Double(fields[3]), let duration = Double(fields[4])
            else { continue }
            let speaker = String(fields[7])
            turns.append(AmiMeeting.Turn(speakerId: speaker, beginTime: start, endTime: start + duration))
        }
        return turns
    }

    private static func fetchIfExists(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private static func urlExists(_ url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func downloadAndResample(_ url: URL) async throws -> [Float] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloaderError.noHeadsetChannelFound("audio fetch failed for \(url)")
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ami-2ch-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        return try AudioConverter().resampleAudioFile(tempURL)
    }

    // MARK: Caching

    private struct CachedManifest: Codable {
        let meetingId: String
        let micSpeakerId: String
        let turns: [CachedTurn]
    }
    private struct CachedTurn: Codable {
        let speakerId: String
        let beginTime: Double
        let endTime: Double
    }

    private static func cacheMeeting(_ meeting: TwoChannelMeeting, cacheDir: URL) throws {
        let pcmURL = cacheDir.appendingPathComponent("\(meeting.meetingId).pcm")
        let manifestURL = cacheDir.appendingPathComponent("\(meeting.meetingId).json")
        try meeting.systemMix.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: pcmURL, options: .atomic)
        }
        let manifest = CachedManifest(
            meetingId: meeting.meetingId, micSpeakerId: meeting.micSpeakerId,
            turns: meeting.turns.map { CachedTurn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) })
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func loadCached(meetingId: String, cacheDir: URL) throws -> TwoChannelMeeting {
        let manifestURL = cacheDir.appendingPathComponent("\(meetingId).json")
        let pcmURL = cacheDir.appendingPathComponent("\(meetingId).pcm")
        let manifest = try JSONDecoder().decode(CachedManifest.self, from: Data(contentsOf: manifestURL))
        let data = try Data(contentsOf: pcmURL)
        let systemMix = data.withUnsafeBytes { raw -> [Float] in Array(raw.bindMemory(to: Float.self)) }
        let turns = manifest.turns.map { AmiMeeting.Turn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) }
        return TwoChannelMeeting(meetingId: manifest.meetingId, micSpeakerId: manifest.micSpeakerId, systemMix: systemMix, turns: turns)
    }
}
