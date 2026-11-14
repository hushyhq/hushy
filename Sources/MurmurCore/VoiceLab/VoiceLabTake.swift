import Foundation

/// Metadata sidecar saved next to each Voice Lab recording (`<id>.json` beside `<id>.wav`).
/// Captures how the take was recorded so later analysis can separate ASR/cleanup quality from
/// capture conditions (device, voice processing, OS version).
public struct VoiceLabTake: Codable, Sendable, Equatable {
    public let promptID: String
    public let category: String
    public let style: VoiceLabPrompt.Style
    public let timestamp: Date
    public let deviceName: String
    public let voiceProcessingEnabled: Bool
    public let osVersion: String
    /// Peak absolute sample value of the raw (pre-normalization) capture.
    public let capturePeak: Float
    /// RMS of the raw (pre-normalization) capture.
    public let captureRMS: Float
    /// Duration of the recording in seconds, derived from sample count at 16 kHz.
    public let durationSeconds: Double

    public init(
        promptID: String, category: String, style: VoiceLabPrompt.Style, timestamp: Date,
        deviceName: String, voiceProcessingEnabled: Bool, osVersion: String,
        capturePeak: Float, captureRMS: Float, durationSeconds: Double
    ) {
        self.promptID = promptID
        self.category = category
        self.style = style
        self.timestamp = timestamp
        self.deviceName = deviceName
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.osVersion = osVersion
        self.capturePeak = capturePeak
        self.captureRMS = captureRMS
        self.durationSeconds = durationSeconds
    }
}

/// One recorded take: the sidecar plus where its audio and metadata files live. Used by both
/// the app (writing takes) and `murmur-eval voicelab` (reading them back).
public struct VoiceLabRecording: Sendable {
    public let take: VoiceLabTake
    public let audioURL: URL
    public let sidecarURL: URL

    public init(take: VoiceLabTake, audioURL: URL, sidecarURL: URL) {
        self.take = take
        self.audioURL = audioURL
        self.sidecarURL = sidecarURL
    }
}

/// Reads/writes take sidecars and discovers recorded sessions on disk.
public enum VoiceLabStorage {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `~/Library/Application Support/Murmur/VoiceLab` (or `$MURMUR_HOME/VoiceLab`).
    public static var root: URL {
        AppPaths.supportDirectory.appendingPathComponent("VoiceLab", isDirectory: true)
    }

    /// One folder per recording session, named by date so re-recording sessions don't collide.
    public static func sessionDirectory(for date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    public static func write(_ take: VoiceLabTake, to sidecarURL: URL) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(take).write(to: sidecarURL, options: .atomic)
    }

    public static func readTake(_ url: URL) throws -> VoiceLabTake {
        try decoder.decode(VoiceLabTake.self, from: Data(contentsOf: url))
    }

    /// Finds every `<id>.wav` + `<id>.json` pair under `directory` (searched recursively, so
    /// callers can point at the VoiceLab root or a single dated session folder).
    public static func discoverRecordings(in directory: URL) throws -> [VoiceLabRecording] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var recordings: [VoiceLabRecording] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let audioURL = url.deletingPathExtension().appendingPathExtension("wav")
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            guard let take = try? readTake(url) else { continue }
            recordings.append(VoiceLabRecording(take: take, audioURL: audioURL, sidecarURL: url))
        }
        return recordings.sorted { $0.take.timestamp < $1.take.timestamp }
    }
}
