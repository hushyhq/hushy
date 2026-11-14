@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// One AMI meeting: its full single-distant-mic (SDM) or headset-mix audio, resampled to
/// 16 kHz mono, and its **official** ground-truth speaker turns (RTTM), per the product owner's
/// requirement that the diarization eval run against officially-annotated audio, not a
/// reconstruction. See `AmiMeetingDownloader` for where both come from.
struct AmiMeeting: Sendable {
    struct Turn: Sendable {
        let speakerId: String
        let beginTime: Double
        let endTime: Double
    }

    let meetingId: String
    let audio: [Float]
    let turns: [Turn]
    var durationSeconds: Double { Double(audio.count) / 16_000 }
}

/// Downloads a small, fixed subset of complete AMI meetings using two independent, official
/// public sources — no reconstruction of ground truth from anything else:
///
/// 1. **Ground-truth RTTM**: `pyannote/AMI-diarization-setup` (GitHub, MIT-licensed tooling
///    repo built directly from the official AMI corpus's manual annotations, the same setup
///    pyannote's own published AMI benchmarks — cited in docs/research/speaker-labeling.md §1.2
///    — use). `lists/{dev,test}.mini.txt` gives the community-standard 3-meeting "mini" subset
///    used for exactly this kind of fast/small AMI eval; `only_words/rttms/{split}/<meeting>.rttm`
///    gives that meeting's ground-truth speaker turns in standard RTTM format.
/// 2. **Audio**: the official AMI Corpus mirror at Edinburgh
///    (`groups.inf.ed.ac.uk/ami/AMICorpusMirror`) serves each meeting's full single-distant-mic
///    (`Array1-0N`, far-field — the realistic "recorded on a laptop" case) or headset-mix
///    (`Mix-Headset`) audio as one direct WAV download — no per-utterance reconstruction needed.
///    Each file is one whole meeting (tens of MB), matching the task's "keep downloads small: a
///    few meetings" instruction far better than downloading a config's thousands of individual
///    utterance clips.
///
/// Every fetch and every cached file's provenance is logged; nothing here is synthesized.
enum AmiMeetingDownloader {
    enum Config: String {
        case sdm  // far-field, single distant mic — the realistic "recorded on a laptop" case.
        case ihm  // headset mix — cleaner signal, closer to pyannote's IHM benchmark condition.
    }

    enum DownloaderError: LocalizedError {
        case network(String)
        case noAudioChannelFound(String)
        var errorDescription: String? {
            switch self {
            case .network(let message): "AMI download failed: \(message)"
            case .noAudioChannelFound(let meeting): "No SDM audio channel resolved for meeting \(meeting)"
            }
        }
    }

    /// AMI's community-standard "mini" subsets, from `pyannote/AMI-diarization-setup/lists/
    /// {dev,test}.mini.txt` — small by design, per the task's size constraint, and a recognizable
    /// subset rather than an arbitrary one. `test.mini` is downloaded by default (unchanged from
    /// before); `dev.mini` was added so `murmur-eval diarize --split tune|test` (see `DiarizeRunner`)
    /// has two independent 3-meeting halves for the "tune on half, report on the other half"
    /// requirement — using `dev.mini` as the tuning half and `test.mini` as the held-out half
    /// mirrors how pyannote's own AMI setup is meant to be used (dev for hyperparameter search,
    /// test for the reported number), rather than an arbitrary split within one list.
    private static let devMiniMeetings = ["ES2003a", "IS1000a", "TS3004a"]
    private static let testMiniMeetings = ["IS1009a", "ES2004a", "TS3003a"]

    /// All meetings across both mini lists, in a stable order — used when a caller wants the tune
    /// half specifically (`split: .tune`), since `download(config:meetingCount:...)`'s own
    /// `meetingCount` only ever prefixes `testMiniMeetings` (kept exactly as it was for every
    /// existing, non-split call site).
    static func meetingIds(for split: EvalSplit) -> [String] {
        switch split {
        case .tune: devMiniMeetings
        case .test: testMiniMeetings
        }
    }

    /// Candidate single-distant-mic channel names to probe per meeting, in order — AMI's mic
    /// array numbering varies by meeting room setup (confirmed empirically: EN2002a resolves at
    /// Array1-02, IS1009a/ES2004a at Array1-01, TS3003a at Array1-03), so this tries the whole
    /// plausible range and uses the first that exists rather than hardcoding one name.
    private static let sdmChannelCandidates = (1...8).map { "Array1-0\($0)" }

    static func download(config: Config, meetingCount: Int, root: URL) async throws -> [AmiMeeting] {
        try await download(config: config, meetingIds: Array(testMiniMeetings.prefix(max(meetingCount, 1))), root: root)
    }

    /// Downloads a specific, caller-chosen set of meetings — used by `--split tune|test` (see
    /// `DiarizeRunner`) to fetch exactly `devMiniMeetings` or `testMiniMeetings` rather than an
    /// arbitrary prefix. Shares the same on-disk cache directory as
    /// `download(config:meetingCount:root:)` (keyed by `config`, not by split), so running both
    /// splits back to back never re-downloads a meeting fetched by the other.
    static func download(config: Config, meetingIds: [String], root: URL) async throws -> [AmiMeeting] {
        let cacheDir = root.appendingPathComponent("ami-meetings-\(config.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var meetings: [AmiMeeting] = []
        for meetingId in meetingIds {
            if let cached = try? loadCachedMeeting(meetingId: meetingId, cacheDir: cacheDir) {
                print("  \(meetingId): using cached audio + official RTTM")
                meetings.append(cached)
                continue
            }
            print("  \(meetingId): fetching official RTTM…")
            let turns = try await fetchOfficialRTTM(meetingId: meetingId)
            print("  \(meetingId): downloading official \(config.rawValue) audio…")
            let audio = try await downloadMeetingAudio(meetingId: meetingId, config: config)
            let meeting = AmiMeeting(meetingId: meetingId, audio: audio, turns: turns)
            try cacheMeeting(meeting, cacheDir: cacheDir)
            meetings.append(meeting)
        }
        return meetings
    }

    // MARK: Official ground-truth RTTM

    /// Fetches `<meetingId>.rttm` from `pyannote/AMI-diarization-setup`'s `only_words/rttms`
    /// tree, trying the `test` split first (where AMI's canonical "mini" meetings live) then
    /// `dev`, and parses it into `AmiMeeting.Turn`s. RTTM format:
    /// `SPEAKER <meeting> <chan> <start> <dur> <NA> <NA> <speaker> <NA> <NA>`.
    private static func fetchOfficialRTTM(meetingId: String) async throws -> [AmiMeeting.Turn] {
        for split in ["test", "dev", "train"] {
            let url = URL(string: "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/\(split)/\(meetingId).rttm")!
            if let data = try? await fetchIfExists(url) {
                return parseRTTM(data)
            }
        }
        throw DownloaderError.network("no official RTTM found for meeting \(meetingId) in any split")
    }

    private static func parseRTTM(_ data: Data) -> [AmiMeeting.Turn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [AmiMeeting.Turn] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // SPEAKER meeting chan start dur <NA> <NA> speaker <NA> <NA>
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

    // MARK: Official audio

    /// Downloads and 16 kHz-resamples one meeting's full audio from the official AMI Corpus
    /// mirror. For `.sdm`, probes `sdmChannelCandidates` until one resolves (HTTP 200); for
    /// `.ihm`, uses the standard `Mix-Headset` file every AMI meeting has.
    private static func downloadMeetingAudio(meetingId: String, config: Config) async throws -> [Float] {
        let base = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/\(meetingId)/audio"
        let url: URL
        switch config {
        case .ihm:
            url = URL(string: "\(base)/\(meetingId).Mix-Headset.wav")!
        case .sdm:
            var resolved: URL?
            for channel in sdmChannelCandidates {
                let candidate = URL(string: "\(base)/\(meetingId).\(channel).wav")!
                if try await urlExists(candidate) {
                    resolved = candidate
                    break
                }
            }
            guard let resolved else { throw DownloaderError.noAudioChannelFound(meetingId) }
            url = resolved
        }
        return try await downloadAndResample(url)
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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloaderError.network("audio fetch failed for \(url)") }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ami-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        return try AudioConverter().resampleAudioFile(tempURL)
    }

    // MARK: Caching

    private struct CachedManifest: Codable {
        let meetingId: String
        let turns: [CachedTurn]
    }
    private struct CachedTurn: Codable {
        let speakerId: String
        let beginTime: Double
        let endTime: Double
    }

    private static func cacheMeeting(_ meeting: AmiMeeting, cacheDir: URL) throws {
        let pcmURL = cacheDir.appendingPathComponent("\(meeting.meetingId).pcm")
        let manifestURL = cacheDir.appendingPathComponent("\(meeting.meetingId).json")
        try meeting.audio.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: pcmURL, options: .atomic)
        }
        let manifest = CachedManifest(
            meetingId: meeting.meetingId,
            turns: meeting.turns.map { CachedTurn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) })
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func loadCachedMeeting(meetingId: String, cacheDir: URL) throws -> AmiMeeting {
        let manifestURL = cacheDir.appendingPathComponent("\(meetingId).json")
        let pcmURL = cacheDir.appendingPathComponent("\(meetingId).pcm")
        let manifest = try JSONDecoder().decode(CachedManifest.self, from: Data(contentsOf: manifestURL))
        let data = try Data(contentsOf: pcmURL)
        let audio = data.withUnsafeBytes { raw -> [Float] in Array(raw.bindMemory(to: Float.self)) }
        let turns = manifest.turns.map { AmiMeeting.Turn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) }
        return AmiMeeting(meetingId: manifest.meetingId, audio: audio, turns: turns)
    }
}
