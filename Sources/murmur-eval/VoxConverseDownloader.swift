@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// One VoxConverse dev-set file: its audio (already 16 kHz mono WAV in the official
/// distribution) and its official ground-truth RTTM turns.
struct VoxConverseFile: Sendable {
    struct Turn: Sendable {
        let speakerId: String
        let beginTime: Double
        let endTime: Double
    }

    let fileId: String
    let audio: [Float]
    let turns: [Turn]
    var durationSeconds: Double { Double(audio.count) / 16_000 }
}

/// Downloads a small, fixed subset of VoxConverse dev-set files with their official RTTM —
/// public, CC-BY-4.0 (see `joonson/voxconverse`'s README), audio-visual diarization dataset
/// extracted from YouTube political debates/news, chosen for high overlapped-speech content.
///
/// Two official sources, no reconstruction:
/// - **RTTM**: `joonson/voxconverse` (GitHub), `dev/<fileId>.rttm` — the dataset's own manual
///   annotations, fetched directly via raw GitHub content.
/// - **Audio**: the official Oxford VGG distribution
///   (`robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_dev_wav.zip`), one ZIP containing
///   every dev-set file (~2 GB total). Downloading the *whole* zip for a handful of files would
///   violate the task's "keep downloads small" instruction, so this fetches only the ZIP's
///   central directory (a few KB, via an HTTP Range request) to locate each wanted entry, then
///   fetches only that entry's compressed byte range and inflates it locally — never downloading
///   the other ~200 files. The VGG server advertises `Accept-Ranges: bytes` (confirmed via HEAD),
///   which is what makes this possible; if it doesn't (a different mirror, a server change),
///   this throws rather than silently downloading the entire archive.
enum VoxConverseDownloader {
    enum DownloaderError: LocalizedError {
        case network(String)
        case rangeRequestsUnsupported
        case entryNotFound(String)
        var errorDescription: String? {
            switch self {
            case .network(let message): "VoxConverse download failed: \(message)"
            case .rangeRequestsUnsupported: "The VoxConverse audio server does not support HTTP Range requests; refusing to download the full ~2 GB archive for a small subset"
            case .entryNotFound(let name): "ZIP entry not found: \(name)"
            }
        }
    }

    /// Which official VoxConverse partition to read. `dev` is the original fixed subset below;
    /// `test` is the v0.3 test partition (232 files), which pyannote-family models report on.
    enum Partition: String, Sendable {
        case dev
        case test

        var audioZipURL: URL {
            URL(string: "https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_\(rawValue)_wav.zip")!
        }
        var zipEntryFolder: String { self == .dev ? "audio" : "voxconverse_test_wav" }
        var cacheFolder: String { "voxconverse-\(rawValue)" }
    }

    /// A fixed, small subset of dev-set file ids, chosen arbitrarily but deterministically
    /// (first N in RTTM directory listing order) — not curated for favorable results.
    /// A fixed, small subset of dev-set file ids, chosen deterministically (first N in
    /// `joonson/voxconverse`'s `dev/` RTTM directory listing) — not curated for favorable
    /// results. Corrected 2026-09-26: the original second-half entries ("aorju", "auzru",
    /// "bmsyn", "bvyvm", "bxcfq") did not exist in the actual `dev/` RTTM listing (all 404,
    /// verified directly against the GitHub API and raw content — likely a transcription slip
    /// from an earlier listing, not a network issue), which meant `--split test` always skipped.
    /// Replaced with the next five real ids from the same directory listing, in the same
    /// alphabetical-first-N spirit as the original five.
    private static let devFileIds = [
        "abjxc", "afjiv", "ahnss", "aisvi", "akthc", "ampme", "asxwr", "atgpi", "aufkn", "azisu",
    ]

    /// The first half of `devFileIds` (tuning) vs. the second half (held-out report), for
    /// `--split tune|test` (see `DiarizeRunner`) — a fixed, disjoint, order-based split of the
    /// same 10-file fixed subset, so tuning never sees the files the reported number is computed
    /// on. `devFileIds` is a `let` array in file-declaration order (not resorted per call), so
    /// this split is deterministic across runs.
    static func fileIds(for split: EvalSplit) -> [String] {
        let half = devFileIds.count / 2
        switch split {
        case .tune: return Array(devFileIds.prefix(half))
        case .test: return Array(devFileIds.suffix(from: half))
        }
    }

    static func download(fileCount: Int, root: URL) async throws -> [VoxConverseFile] {
        try await download(fileIds: Array(devFileIds.prefix(max(fileCount, 1))), root: root)
    }

    /// Downloads a specific, caller-chosen set of files — used by `--split tune|test` to fetch
    /// exactly one disjoint half of `devFileIds`. Shares the same on-disk cache as
    /// `download(fileCount:root:)`.
    static func download(fileIds ids: [String], root: URL, partition: Partition = .dev) async throws -> [VoxConverseFile] {
        let cacheDir = root.appendingPathComponent(partition.cacheFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var files: [VoxConverseFile] = []

        // Resolve the ZIP's central directory once per run (needed to locate byte ranges for
        // any file not already cached).
        var zipReader: RangeZipReader?
        func reader() async throws -> RangeZipReader {
            if let zipReader { return zipReader }
            let built = try await RangeZipReader.open(url: partition.audioZipURL)
            zipReader = built
            return built
        }

        for id in ids {
            if let cached = try? loadCachedFile(id: id, cacheDir: cacheDir) {
                print("  \(id): using cached audio + official RTTM")
                files.append(cached)
                continue
            }
            print("  \(id): fetching official RTTM…")
            let turns = try await fetchOfficialRTTM(id: id, partition: partition)
            print("  \(id): fetching official audio via ranged ZIP entry (not the full archive)…")
            let zip = try await reader()
            let audio = try await zip.extractAndResample(entryPath: "\(partition.zipEntryFolder)/\(id).wav")
            let file = VoxConverseFile(fileId: id, audio: audio, turns: turns)
            try cacheFile(file, cacheDir: cacheDir)
            files.append(file)
        }
        return files
    }

    private static func fetchOfficialRTTM(id: String, partition: Partition) async throws -> [VoxConverseFile.Turn] {
        let url = URL(string: "https://raw.githubusercontent.com/joonson/voxconverse/master/\(partition.rawValue)/\(id).rttm")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloaderError.network("RTTM fetch failed for \(id)")
        }
        return parseRTTM(data)
    }

    private static func parseRTTM(_ data: Data) -> [VoxConverseFile.Turn] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [VoxConverseFile.Turn] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 8, fields[0] == "SPEAKER",
                  let start = Double(fields[3]), let duration = Double(fields[4])
            else { continue }
            turns.append(VoxConverseFile.Turn(speakerId: String(fields[7]), beginTime: start, endTime: start + duration))
        }
        return turns
    }

    // MARK: Caching

    private struct CachedManifest: Codable {
        let fileId: String
        let turns: [CachedTurn]
    }
    private struct CachedTurn: Codable {
        let speakerId: String
        let beginTime: Double
        let endTime: Double
    }

    private static func cacheFile(_ file: VoxConverseFile, cacheDir: URL) throws {
        let pcmURL = cacheDir.appendingPathComponent("\(file.fileId).pcm")
        let manifestURL = cacheDir.appendingPathComponent("\(file.fileId).json")
        try file.audio.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(to: pcmURL, options: .atomic)
        }
        let manifest = CachedManifest(
            fileId: file.fileId,
            turns: file.turns.map { CachedTurn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) })
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func loadCachedFile(id: String, cacheDir: URL) throws -> VoxConverseFile {
        let manifestURL = cacheDir.appendingPathComponent("\(id).json")
        let pcmURL = cacheDir.appendingPathComponent("\(id).pcm")
        let manifest = try JSONDecoder().decode(CachedManifest.self, from: Data(contentsOf: manifestURL))
        let data = try Data(contentsOf: pcmURL)
        let audio = data.withUnsafeBytes { raw -> [Float] in Array(raw.bindMemory(to: Float.self)) }
        let turns = manifest.turns.map { VoxConverseFile.Turn(speakerId: $0.speakerId, beginTime: $0.beginTime, endTime: $0.endTime) }
        return VoxConverseFile(fileId: manifest.fileId, audio: audio, turns: turns)
    }
}

/// Reads a single named entry out of a remote ZIP file using HTTP Range requests, without
/// downloading the whole archive: fetches the End-Of-Central-Directory record + central
/// directory (a few KB, from the end of the file), locates the wanted entry's local-file-header
/// offset and compressed size, fetches just those bytes, and inflates them (ZIP's DEFLATE or
/// stored). This is the standard trick for "one file out of a huge remote ZIP" and is why
/// `VoxConverseDownloader` never has to pull the archive's other ~200 files.
actor RangeZipReader {
    private let url: URL
    private let totalSize: Int64
    private let centralDirectoryOffset: UInt32
    private let centralDirectorySize: UInt32
    private var entries: [String: (offset: UInt32, compressedSize: UInt32, method: UInt16)] = [:]

    enum ReaderError: LocalizedError {
        case rangeUnsupported
        case malformedZip(String)
        var errorDescription: String? {
            switch self {
            case .rangeUnsupported: "Server does not support HTTP Range requests"
            case .malformedZip(let detail): "Malformed ZIP: \(detail)"
            }
        }
    }

    private init(url: URL, totalSize: Int64, cdOffset: UInt32, cdSize: UInt32) {
        self.url = url
        self.totalSize = totalSize
        self.centralDirectoryOffset = cdOffset
        self.centralDirectorySize = cdSize
    }

    static func open(url: URL) async throws -> RangeZipReader {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 30
        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
        guard let http = headResponse as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
              let totalSize = Int64(lengthString)
        else {
            throw VoxConverseDownloader.DownloaderError.rangeRequestsUnsupported
        }

        // EOCD record is within the last 65557 bytes (max comment length + fixed fields).
        let tailStart = max(0, totalSize - 65_557)
        let tail = try await fetchRange(url: url, start: tailStart, end: totalSize - 1)
        guard let eocdOffset = findEOCD(in: tail) else {
            throw ReaderError.malformedZip("EOCD signature not found")
        }
        let eocd = tail[eocdOffset...]
        let cdSize = readUInt32LE(eocd, at: 12)
        let cdOffset = readUInt32LE(eocd, at: 16)

        let reader = RangeZipReader(url: url, totalSize: totalSize, cdOffset: cdOffset, cdSize: cdSize)
        try await reader.loadCentralDirectory()
        return reader
    }

    private func loadCentralDirectory() async throws {
        let data = try await Self.fetchRange(
            url: url, start: Int64(centralDirectoryOffset), end: Int64(centralDirectoryOffset) + Int64(centralDirectorySize) - 1)
        var offset = 0
        var parsed: [String: (offset: UInt32, compressedSize: UInt32, method: UInt16)] = [:]
        while offset + 46 <= data.count {
            guard Self.readUInt32LE(data, at: offset) == 0x02014b50 else { break }  // central dir file header signature
            let method = Self.readUInt16LE(data, at: offset + 10)
            let compressedSize = Self.readUInt32LE(data, at: offset + 20)
            let nameLength = Int(Self.readUInt16LE(data, at: offset + 28))
            let extraLength = Int(Self.readUInt16LE(data, at: offset + 30))
            let commentLength = Int(Self.readUInt16LE(data, at: offset + 32))
            let localHeaderOffset = Self.readUInt32LE(data, at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count,
                  let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8)
            else { break }
            parsed[name] = (localHeaderOffset, compressedSize, method)
            offset = nameStart + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    /// Fetches and inflates one entry, resampling it to 16 kHz mono for the diarizer.
    func extractAndResample(entryPath: String) async throws -> [Float] {
        guard let entry = entries[entryPath] else { throw VoxConverseDownloader.DownloaderError.entryNotFound(entryPath) }

        // Read the local file header at `entry.offset` to find where the actual compressed data
        // starts (its own name/extra fields may differ in length from the central directory's).
        let headerProbe = try await Self.fetchRange(url: url, start: Int64(entry.offset), end: Int64(entry.offset) + 30 + 512)
        guard Self.readUInt32LE(headerProbe, at: 0) == 0x04034b50 else {
            throw ReaderError.malformedZip("local file header signature mismatch for \(entryPath)")
        }
        let nameLength = Int(Self.readUInt16LE(headerProbe, at: 26))
        let extraLength = Int(Self.readUInt16LE(headerProbe, at: 28))
        let dataStart = Int64(entry.offset) + 30 + Int64(nameLength) + Int64(extraLength)
        let dataEnd = dataStart + Int64(entry.compressedSize) - 1

        let compressed = try await Self.fetchRange(url: url, start: dataStart, end: dataEnd)
        let raw: Data
        if entry.method == 0 {
            raw = compressed  // stored, no compression
        } else {
            raw = try inflate(compressed)
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voxconverse-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try raw.write(to: tempURL)
        return try AudioConverter().resampleAudioFile(tempURL)
    }

    /// Raw DEFLATE (no zlib/gzip header, matching ZIP's compression method 8) via zlib's C API.
    private func inflate(_ compressed: Data) throws -> Data {
        try Zlib.inflateRaw(compressed)
    }

    // MARK: Byte helpers

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }
    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[data.startIndex + offset + i]) << (8 * i) }
        return value
    }
    private static func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var i = bytes.count - 4
        while i >= 0 {
            if bytes[i] == signature[0], bytes[i + 1] == signature[1], bytes[i + 2] == signature[2], bytes[i + 3] == signature[3] {
                return i
            }
            i -= 1
        }
        return nil
    }

    private static func fetchRange(url: URL, start: Int64, end: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw VoxConverseDownloader.DownloaderError.network("range fetch failed (\(start)-\(end))")
        }
        return data
    }
}
