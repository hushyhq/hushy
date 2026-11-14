import FluidAudio
import Foundation
import MurmurCore

/// One recording with its official reference turns.
struct BakeoffFile {
    let id: String
    let audio: [Float]
    let reference: [DERSegment]
    var durationSeconds: Double { Double(audio.count) / 16_000 }
}

/// The public sets the bakeoff reads. Files load one at a time so peak memory reflects one meeting,
/// as it does in the app.
enum BakeoffDataset: String, CaseIterable {
    /// AMI single distant mic, the standard 16-meeting test split (EN2002, ES2004, IS1009, TS3003 a-d).
    case amiSdm = "ami-sdm"
    /// AMI single distant mic, dev meetings, for tuning a threshold without touching the test split.
    case amiSdmDev = "ami-sdm-dev"
    /// VoxConverse v0.3 test, first files by id. Nemotron 3 was trained on it (see its card).
    case voxconverseTest = "voxconverse-test"
    /// NOTSOFAR-1 eval, single-channel device, 17 meetings (see `NotsofarDownloader.meetings`).
    case notsofarSc = "notsofar-sc"

    static let amiTestMeetings = ["EN2002", "ES2004", "IS1009", "TS3003"].flatMap { m in ["a", "b", "c", "d"].map { m + $0 } }
    static let amiDevMeetings = ["ES2011", "IS1008", "TS3004"].flatMap { m in ["a", "b", "c", "d"].map { m + $0 } }

    /// The first files by id in `joonson/voxconverse/test`, not chosen for results.
    static let voxconverseTestIds = [
        "aepyx", "aggyz", "aiqwk", "aorju", "auzru", "bgvvt", "bidnq", "bjruf", "bmsyn", "bpzsc",
    ]

    var fileIds: [String] {
        switch self {
        case .amiSdm: Self.amiTestMeetings
        case .amiSdmDev: Self.amiDevMeetings
        case .voxconverseTest: Self.voxconverseTestIds
        case .notsofarSc: NotsofarDownloader.meetings.map(\.id)
        }
    }

    func load(id: String, root: URL) async throws -> BakeoffFile {
        switch self {
        case .amiSdm, .amiSdmDev:
            return try await AmiSdmFiles.load(id: id, split: self == .amiSdm ? "test" : "dev", root: root)
        case .voxconverseTest:
            guard let file = try await VoxConverseDownloader.download(fileIds: [id], root: root, partition: .test).first else {
                throw EvalError.missing("VoxConverse file \(id) did not download")
            }
            return BakeoffFile(
                id: id, audio: file.audio,
                reference: file.turns.map { DERSegment(speaker: $0.speakerId, start: $0.beginTime, end: $0.endTime) })
        case .notsofarSc:
            let device = NotsofarDownloader.meetings.first { $0.id == id }?.device ?? "sc_meetup_0"
            return try await NotsofarDownloader.load(id: id, device: device, root: root)
        }
    }
}

/// AMI single-distant-mic meetings kept as the official files on disk: the Edinburgh mirror's
/// `Array1-01` WAV and `pyannote/AMI-diarization-setup`'s `only_words` RTTM. A file already on disk
/// is never fetched again, so the set can be filled ahead of a run.
enum AmiSdmFiles {
    static func load(id: String, split: String, root: URL) async throws -> BakeoffFile {
        let wav = root.appendingPathComponent("ami-sdm/\(id).Array1-01.wav")
        let rttm = root.appendingPathComponent("ami-sdm/\(id).rttm")
        try await BakeoffDownload.ensure(
            URL(string: "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/\(id)/audio/\(id).Array1-01.wav")!, at: wav)
        try await BakeoffDownload.ensure(
            URL(string: "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/\(split)/\(id).rttm")!, at: rttm)
        return BakeoffFile(id: id, audio: try AudioConverter().resampleAudioFile(wav), reference: RTTM.parse(try Data(contentsOf: rttm)))
    }
}

enum RTTM {
    /// `SPEAKER <file> <chan> <start> <dur> <NA> <NA> <speaker> <NA> <NA>`
    static func parse(_ data: Data) -> [DERSegment] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 8, fields[0] == "SPEAKER", let start = Double(fields[3]), let duration = Double(fields[4]) else { return nil }
            return DERSegment(speaker: String(fields[7]), start: start, end: start + duration)
        }
    }
}

enum BakeoffDownload {
    /// Downloads `url` to `path` unless it is already there. The file lands under a temporary name
    /// first, so an interrupted download never looks complete.
    static func ensure(_ url: URL, at path: URL) async throws {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        print("  fetching \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temp)
            throw EvalError.missing("download failed (\((response as? HTTPURLResponse)?.statusCode ?? -1)): \(url.absoluteString)")
        }
        try FileManager.default.moveItem(at: temp, to: path)
    }
}
