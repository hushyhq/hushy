import Foundation

/// A downloaded evaluation clip.
struct EvalClip: Codable {
    let id: String
    let audioPath: String
    /// Verbatim transcript (what was said).
    let reference: String
    /// Fluent transcript (what the speaker meant), when the dataset provides one.
    let fluentReference: String?
    /// Grouping label such as the speaker's accent, when the dataset has one.
    var group: String? = nil
    /// Row index in the source split, for provenance.
    var sourceRowIndex: Int? = nil
    /// Speaker id, when the dataset has one (EdAcc) — lets accent results bootstrap over speakers.
    var speaker: String? = nil
}

/// Provenance recorded alongside a dataset's clips so a manifest can be audited independently
/// of the code that produced it (dataset id, split, sampling method, license, row ids).
struct DatasetManifest: Codable {
    var dataset: String
    var config: String
    var split: String
    var license: String
    var samplingSeed: Int?
    var samplingMethod: String
    var requestedCount: Int
    var totalSourceRows: Int?
    var clips: [EvalClip]
}

/// Public speech datasets fetched through the Hugging Face datasets-server API.
enum Dataset: String, CaseIterable {
    case librispeechClean = "librispeech-clean"
    case librispeechOther = "librispeech-other"
    case disfluency
    case svarah
    case accents
    case amiHeadset = "ami-headset"
    case amiFarField = "ami-farfield"
    case earnings = "earnings22"
    case tedlium
    case voxpopuli
    /// EdAcc rows labeled `accent == "Indian English"` — see `filterAccent` — used by
    /// `murmur-eval accent` as the Indian-accented English test set (see
    /// `.claude/DECISIONS.md`, "Indian-accent ASR accuracy": Svarah is gated on Hugging Face
    /// with no token available in this environment, so EdAcc's own Indian English subset,
    /// which is ungated and CC-BY-4.0, is used instead).
    case edaccIndian = "edacc-indian"
    /// Same EdAcc split, filtered to `accent == "Mainstream US English"` — the size-matched US
    /// control set `murmur-eval accent` reports the accent penalty against.
    case edaccUSControl = "edacc-us-control"
    case fleurs
    case fleursSpanish = "fleurs-es"
    case fleursFrench = "fleurs-fr"
    case fleursGerman = "fleurs-de"
    case fleursItalian = "fleurs-it"
    case peoplesSpeech = "peoples-speech"
    case mlsSpanish = "mls-es"
    case mlsFrench = "mls-fr"
    case mlsGerman = "mls-de"
    case mlsItalian = "mls-it"
    /// The exact test sets and reference texts the Hugging Face Open ASR Leaderboard scores
    /// (`hf-audio/open-asr-leaderboard`, ungated), so Hushy's WER sits next to published numbers
    /// on identical audio. See `murmur-eval us-english` and docs/product/US-ENGLISH-ACCURACY.md.
    case oasrLibrispeechClean = "oasr-librispeech-clean"
    case oasrLibrispeechOther = "oasr-librispeech-other"
    case oasrEarnings22 = "oasr-earnings22"
    case oasrCommonVoice = "oasr-commonvoice"

    /// The 4 non-English languages `murmur-eval multilang` measures WER for — see
    /// .claude/DECISIONS.md ("Multi-language dictation"). Originally FLEURS
    /// (`fleursSpanish`/`fleursFrench`/`fleursGerman`/`fleursItalian`), swapped to
    /// Multilingual LibriSpeech per-language configs because every FLEURS config's
    /// datasets-server `/rows` endpoint 500s ("Parquet error: Scan size limit exceeded") —
    /// FLEURS' row groups exceed the server's 300 MB scan cap, so no offset/length request
    /// against it can ever succeed. See the `mls*` cases below for why this is a safe swap.
    static let multilangDatasets: [Dataset] = [.mlsSpanish, .mlsFrench, .mlsGerman, .mlsItalian]

    var source: (dataset: String, config: String, split: String) {
        switch self {
        case .librispeechClean: ("openslr/librispeech_asr", "clean", "test")
        case .librispeechOther: ("openslr/librispeech_asr", "other", "test")
        case .disfluency: ("amaai-lab/DisfluencySpeech", "default", "test")
        case .svarah: ("ai4bharat/Svarah", "default", "test")
        case .accents: ("edinburghcstr/edacc", "default", "test")
        case .amiHeadset: ("edinburghcstr/ami", "ihm", "test")
        case .amiFarField: ("edinburghcstr/ami", "sdm", "test")
        case .earnings: ("distil-whisper/earnings22", "chunked", "test")
        case .tedlium: ("distil-whisper/tedlium", "release3", "test")
        case .voxpopuli: ("facebook/voxpopuli", "en", "test")
        case .edaccIndian, .edaccUSControl: ("edinburghcstr/edacc", "default", "test")
        case .fleurs: ("google/fleurs", "en_us", "test")
        // FLEURS config codes (google/fleurs dataset card): es_419 is the only Spanish config
        // (Latin American Spanish read speech — there is no es_es config in this dataset); the
        // rest are the plain <lang>_<region> forms.
        case .fleursSpanish: ("google/fleurs", "es_419", "test")
        case .fleursFrench: ("google/fleurs", "fr_fr", "test")
        case .fleursGerman: ("google/fleurs", "de_de", "test")
        case .fleursItalian: ("google/fleurs", "it_it", "test")
        case .peoplesSpeech: ("MLCommons/peoples_speech", "test", "test")
        // Multilingual LibriSpeech (MLS): per-language configs, each dataset-server-friendly
        // (small parquet row groups — no scan-size-limit failures, unlike FLEURS above).
        case .mlsSpanish: ("facebook/multilingual_librispeech", "spanish", "test")
        case .mlsFrench: ("facebook/multilingual_librispeech", "french", "test")
        case .mlsGerman: ("facebook/multilingual_librispeech", "german", "test")
        case .mlsItalian: ("facebook/multilingual_librispeech", "italian", "test")
        case .oasrLibrispeechClean: ("hf-audio/open-asr-leaderboard", "librispeech", "test.clean")
        case .oasrLibrispeechOther: ("hf-audio/open-asr-leaderboard", "librispeech", "test.other")
        case .oasrEarnings22: ("hf-audio/open-asr-leaderboard", "earnings22", "test")
        case .oasrCommonVoice: ("hf-audio/open-asr-leaderboard", "common_voice", "test")
        }
    }

    var summary: String {
        switch self {
        case .librispeechClean: "LibriSpeech test-clean — read audiobook speech, the standard ASR benchmark"
        case .librispeechOther: "LibriSpeech test-other — harder, noisier read speech"
        case .disfluency: "DisfluencySpeech — casual speech with fillers and false starts, plus fluent references"
        case .svarah: "Svarah — Indian-accented English from many speakers (gated: set HF_TOKEN)"
        case .accents: "EdAcc — conversational English across 40+ accents, labeled per speaker"
        case .amiHeadset: "AMI meetings, headset mic — spontaneous multi-party speech"
        case .amiFarField: "AMI meetings, one mic across the room — the notes/meetings case"
        case .earnings: "Earnings22 — company earnings calls, many accents, numbers and jargon"
        case .tedlium: "TED-LIUM 3 — talks"
        case .voxpopuli: "VoxPopuli — European Parliament speeches, non-native English"
        case .edaccIndian: "EdAcc, Indian English speakers — conversational Indian-accented English (Svarah substitute, see Dataset.edaccIndian)"
        case .edaccUSControl: "EdAcc, Mainstream US English speakers — size-matched control for the accent-penalty comparison"
        case .fleurs: "FLEURS en-US — read sentences"
        case .fleursSpanish: "FLEURS es-419 — read sentences, Spanish"
        case .fleursFrench: "FLEURS fr-FR — read sentences, French"
        case .fleursGerman: "FLEURS de-DE — read sentences, German"
        case .fleursItalian: "FLEURS it-IT — read sentences, Italian"
        case .peoplesSpeech: "People's Speech (MLCommons) — human-verified, lowercase/unpunctuated transcripts, CC-BY/CC-BY-SA"
        case .mlsSpanish: "Multilingual LibriSpeech — read audiobook speech, Spanish"
        case .mlsFrench: "Multilingual LibriSpeech — read audiobook speech, French"
        case .mlsGerman: "Multilingual LibriSpeech — read audiobook speech, German"
        case .mlsItalian: "Multilingual LibriSpeech — read audiobook speech, Italian"
        case .oasrLibrispeechClean: "LibriSpeech test-clean, full 2,620 utterances (Open ASR Leaderboard copy) — read audiobooks"
        case .oasrLibrispeechOther: "LibriSpeech test-other, full 2,939 utterances (Open ASR Leaderboard copy) — harder read audiobooks"
        case .oasrEarnings22: "Earnings-22 test, 2,741 segments (Open ASR Leaderboard copy) — earnings calls, numbers, business vocabulary, global accents"
        case .oasrCommonVoice: "Common Voice 9 English test (Open ASR Leaderboard copy, no accent labels) — crowd-sourced read sentences, all accents"
        }
    }

    /// License string recorded in the manifest for provenance.
    var license: String {
        switch self {
        case .peoplesSpeech: "CC-BY-SA-4.0 / CC-BY-4.0 (per-source, ungated MLCommons/peoples_speech test split)"
        case .librispeechClean, .librispeechOther: "CC-BY-4.0 (LibriVox audiobooks)"
        case .accents, .edaccIndian, .edaccUSControl: "CC-BY-4.0 (EdAcc)"
        case .oasrLibrispeechClean, .oasrLibrispeechOther: "CC-BY-4.0 (LibriSpeech, via hf-audio/open-asr-leaderboard)"
        case .oasrEarnings22: "CC-BY-SA-4.0 (Earnings-22, via hf-audio/open-asr-leaderboard)"
        case .oasrCommonVoice: "CC0-1.0 (Mozilla Common Voice 9, via hf-audio/open-asr-leaderboard)"
        case .mlsSpanish, .mlsFrench, .mlsGerman, .mlsItalian:
            "CC-BY-4.0 (Multilingual LibriSpeech; LibriVox audiobooks, same lineage as LibriSpeech)"
        default: "See upstream dataset card"
        }
    }

    /// Whether rows should be sampled deterministically and spread across the whole split
    /// (as opposed to scanned sequentially from offset 0, which biases toward early shards).
    var usesDeterministicSampling: Bool {
        self == .peoplesSpeech || self == .oasrCommonVoice
    }

    /// Restricts a scan to rows whose `accent` column equals this value — used by
    /// `edaccIndian`/`edaccUSControl` to carve two accent-matched subsets out of the same
    /// shared `edinburghcstr/edacc` split without needing a second dataset source.
    var filterAccent: String? {
        switch self {
        case .edaccIndian: "Indian English"
        case .edaccUSControl: "Mainstream US English"
        default: nil
        }
    }

    /// Large sets fetched only when named explicitly — `murmur-eval download` with no dataset
    /// (i.e. "all") skips them so a routine refresh doesn't pull several GB.
    var isOptIn: Bool { rawValue.hasPrefix("oasr-") }

    func directory(root: URL) -> URL { root.appendingPathComponent(rawValue, isDirectory: true) }

    func manifest(root: URL) -> URL { directory(root: root).appendingPathComponent("manifest.json") }

    /// Where in-progress downloads checkpoint, so a killed/interrupted run can resume without
    /// re-fetching or re-downloading clips it already saved.
    func checkpoint(root: URL) -> URL { directory(root: root).appendingPathComponent("manifest.partial.json") }

    func load(root: URL) throws -> [EvalClip] {
        try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifest(root: root)))
    }

    /// Picks the verbatim and fluent transcript fields from a dataset row.
    func transcripts(from row: [String: Any]) -> (String, String?)? {
        switch self {
        case .disfluency:
            guard let verbatim = row["transcript_a"] as? String else { return nil }
            return (verbatim, row["transcript_c"] as? String)
        default:
            // Datasets name their transcript field differently; take the first present.
            for key in ["text", "transcription", "raw_text", "normalized_text", "raw_transcription", "sentence", "transcript"] {
                if let text = row[key] as? String, !text.isEmpty { return (text, nil) }
            }
            return nil
        }
    }

    /// Label used to balance and break down results (e.g. accent).
    func group(from row: [String: Any]) -> String? {
        row["accent"] as? String ?? row["l1"] as? String
    }
}

/// Outcome of a dataset download attempt, printed as an explicit per-dataset status line
/// rather than left to be inferred from a raw clip count.
struct DownloadResult {
    let dataset: Dataset
    let requested: Int
    let downloaded: Int
    let skippedExisting: Int
    let failed: Int
    let failureReasons: [String]

    var statusLine: String {
        var parts = ["downloaded \(downloaded)/\(requested)"]
        if skippedExisting > 0 { parts.append("skipped \(skippedExisting) (already on disk)") }
        if failed > 0 {
            let reasons = Set(failureReasons).sorted().prefix(3).joined(separator: "; ")
            parts.append("failed \(failed) (\(reasons))")
        }
        return parts.joined(separator: ", ")
    }
}

enum Downloader {
    static let pageSize = 100

    /// `perGroup` caps clips per group (e.g. accent) so rare groups are represented; the scan
    /// stops after `maxScan` rows. `seed` is used only by datasets that opt into deterministic
    /// spread-sampling (see `Dataset.usesDeterministicSampling`); it has no effect otherwise.
    static func download(
        _ dataset: Dataset, limit: Int, perGroup: Int? = nil, maxScan: Int = 20_000, seed: UInt64 = 42, root: URL
    ) async throws -> DownloadResult {
        if dataset.usesDeterministicSampling {
            return try await downloadSampled(dataset, limit: limit, seed: seed, root: root)
        }
        return try await downloadSequential(dataset, limit: limit, perGroup: perGroup, maxScan: maxScan, root: root)
    }

    /// Original sequential scan from offset 0, used by datasets where an early-split scan is an
    /// acceptable sample (most cached corpora here are already shuffled or small enough that a
    /// prefix is representative). Resumes from a checkpoint if one exists on disk.
    private static func downloadSequential(
        _ dataset: Dataset, limit: Int, perGroup: Int?, maxScan: Int, root: URL
    ) async throws -> DownloadResult {
        let folder = dataset.directory(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clips: [EvalClip] = (try? loadCheckpoint(dataset, root: root)) ?? []
        var perGroupCount: [String: Int] = [:]
        for clip in clips { perGroupCount[clip.group ?? "", default: 0] += 1 }
        var offset = 0
        var failed = 0
        var failureReasons: [String] = []
        var skippedExisting = 0
        // A dataset-wide accent filter (edaccIndian/edaccUSControl) selects a minority of rows,
        // so — like `perGroup` — always fetch full pages rather than shrinking `length` to
        // `limit - clips.count`, which would starve the scan long before `limit` is reached.
        let fetchFullPages = perGroup != nil || dataset.filterAccent != nil
        while clips.count < limit, offset < maxScan {
            let rows: [[String: Any]]
            do {
                rows = try await fetchRowsWithBackoff(
                    dataset, offset: offset, length: fetchFullPages ? pageSize : min(pageSize, limit - clips.count))
            } catch {
                failureReasons.append(error.localizedDescription)
                failed += 1
                break
            }
            if rows.isEmpty { break }
            for (index, row) in rows.enumerated() {
                if clips.count >= limit { break }
                let group = dataset.group(from: row)
                if let perGroup, perGroupCount[group ?? "", default: 0] >= perGroup { continue }
                if let filterAccent = dataset.filterAccent, group != filterAccent { continue }
                guard let (reference, fluent) = dataset.transcripts(from: row),
                      !reference.contains("IGNORE_TIME_SEGMENT"),
                      !reference.trimmingCharacters(in: .whitespaces).isEmpty,
                      let audio = (row["audio"] as? [[String: Any]])?.first ?? (row["audio"] as? [String: Any]).map({ [$0] })?.first,
                      let source = audio["src"] as? String, let url = URL(string: source)
                else { continue }
                let rowIndex = offset + index
                let id = String(format: "%@-%05d", dataset.rawValue, rowIndex)
                let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                let destination = folder.appendingPathComponent("\(id).\(ext)")
                if FileManager.default.fileExists(atPath: destination.path) {
                    skippedExisting += 1
                } else {
                    do {
                        try await downloadFileWithBackoff(url, to: destination)
                    } catch {
                        failed += 1
                        failureReasons.append(error.localizedDescription)
                        continue
                    }
                }
                clips.append(EvalClip(
                    id: id, audioPath: destination.path, reference: reference, fluentReference: fluent,
                    group: group, sourceRowIndex: rowIndex))
                perGroupCount[group ?? "", default: 0] += 1
                try? saveCheckpoint(clips, dataset: dataset, root: root)
            }
            offset += rows.count
            print("  \(dataset.rawValue): \(clips.count)/\(limit)")
        }
        try finalizeManifest(
            clips, dataset: dataset, root: root, samplingMethod: "sequential-scan-from-offset-0", seed: nil,
            requestedCount: limit, totalSourceRows: nil)
        return DownloadResult(
            dataset: dataset, requested: limit, downloaded: clips.count, skippedExisting: skippedExisting,
            failed: failed, failureReasons: failureReasons)
    }

    /// Deterministic sample spread across the whole split: fetches the split's row count, picks
    /// `limit` row indices with a fixed-seed PRNG spread evenly across shards/offsets (not just
    /// the first N rows), then fetches those rows in per-page batches. Resumable via checkpoint.
    private static func downloadSampled(_ dataset: Dataset, limit: Int, seed: UInt64, root: URL) async throws -> DownloadResult {
        let folder = dataset.directory(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let totalRows = try await fetchSplitRowCount(dataset)
        let sampleIndices = deterministicSample(count: min(limit, totalRows), from: totalRows, seed: seed)

        var existing = (try? loadCheckpoint(dataset, root: root)) ?? []
        var doneIndices = Set(existing.compactMap(\.sourceRowIndex))
        var failed = 0
        var failureReasons: [String] = []
        var skippedExisting = 0

        // Sort the remaining target indices, then fetch each with a page big enough to also
        // pick up any other sampled indices that happen to fall in the same page, so a run of
        // nearby sample points costs one request instead of several.
        let remainingSet = Set(sampleIndices).subtracting(doneIndices)
        let remaining = remainingSet.sorted()
        var index = 0
        while index < remaining.count {
            let rowIndex = remaining[index]
            let length = min(pageSize, totalRows - rowIndex)
            let rows: [[String: Any]]
            do {
                rows = try await fetchRowsWithBackoff(dataset, offset: rowIndex, length: length)
            } catch {
                failureReasons.append(error.localizedDescription)
                failed += 1
                index += 1
                continue
            }
            // Consume every target index this page happened to cover.
            for (offsetInPage, row) in rows.enumerated() {
                let thisRowIndex = rowIndex + offsetInPage
                guard remainingSet.contains(thisRowIndex), !doneIndices.contains(thisRowIndex) else { continue }
                guard let (reference, fluent) = dataset.transcripts(from: row),
                      let audio = (row["audio"] as? [[String: Any]])?.first ?? (row["audio"] as? [String: Any]).map({ [$0] })?.first,
                      let source = audio["src"] as? String, let url = URL(string: source)
                else { continue }
                let id = String(format: "%@-%06d", dataset.rawValue, thisRowIndex)
                let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                let destination = folder.appendingPathComponent("\(id).\(ext)")
                if FileManager.default.fileExists(atPath: destination.path) {
                    skippedExisting += 1
                } else {
                    do {
                        try await downloadFileWithBackoff(url, to: destination)
                    } catch {
                        failed += 1
                        failureReasons.append(error.localizedDescription)
                        continue
                    }
                }
                existing.append(EvalClip(
                    id: id, audioPath: destination.path, reference: reference, fluentReference: fluent,
                    group: dataset.group(from: row), sourceRowIndex: thisRowIndex))
                doneIndices.insert(thisRowIndex)
                try? saveCheckpoint(existing, dataset: dataset, root: root)
            }
            print("  \(dataset.rawValue): \(existing.count)/\(limit)")
            // Advance past every index covered by this page fetch.
            while index < remaining.count, remaining[index] < rowIndex + length { index += 1 }
        }

        try finalizeManifest(
            existing, dataset: dataset, root: root, samplingMethod: "deterministic-spread-seed-\(seed)",
            seed: Int(seed), requestedCount: limit, totalSourceRows: totalRows)
        return DownloadResult(
            dataset: dataset, requested: limit, downloaded: existing.count, skippedExisting: skippedExisting,
            failed: failed, failureReasons: failureReasons)
    }

    /// Picks `count` distinct row indices spread across `[0, totalRows)` using a fixed-seed
    /// PRNG, so the sample is reproducible and not biased toward the first shard(s).
    static func deterministicSample(count: Int, from totalRows: Int, seed: UInt64) -> Set<Int> {
        guard totalRows > 0, count > 0 else { return [] }
        var generator = SplitMix64(seed: seed)
        if count >= totalRows { return Set(0..<totalRows) }
        // Stratified pick: split the split into `count` equal bands and pick one index per band,
        // jittered within the band by the seeded generator, so coverage spreads across the whole
        // split (and thus across parquet shards) instead of clustering.
        var indices = Set<Int>()
        let bandSize = Double(totalRows) / Double(count)
        for band in 0..<count {
            let bandStart = Int(Double(band) * bandSize)
            let bandEnd = min(totalRows - 1, Int(Double(band + 1) * bandSize) - 1)
            let span = max(1, bandEnd - bandStart + 1)
            var candidate = bandStart + Int(generator.next() % UInt64(span))
            while indices.contains(candidate), span > 1 {
                candidate = bandStart + Int(generator.next() % UInt64(span))
            }
            indices.insert(min(candidate, totalRows - 1))
        }
        return indices
    }

    private static func fetchSplitRowCount(_ dataset: Dataset) async throws -> Int {
        let source = dataset.source
        var components = URLComponents(string: "https://datasets-server.huggingface.co/size")!
        components.queryItems = [
            URLQueryItem(name: "dataset", value: source.dataset),
            URLQueryItem(name: "config", value: source.config),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response, retryable) = try await sendWithBackoff(request)
        guard !retryable, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EvalError.download("\(source.dataset): could not fetch split size")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let splits = (json?["size"] as? [String: Any])?["splits"] as? [[String: Any]]
        guard let split = splits?.first(where: { $0["split"] as? String == source.split }),
              let rows = split["num_rows"] as? Int
        else {
            throw EvalError.download("\(source.dataset): missing num_rows for split \(source.split)")
        }
        return rows
    }

    // MARK: Checkpointing

    private static func loadCheckpoint(_ dataset: Dataset, root: URL) throws -> [EvalClip] {
        try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: dataset.checkpoint(root: root)))
    }

    private static func saveCheckpoint(_ clips: [EvalClip], dataset: Dataset, root: URL) throws {
        // Written atomically so a killed process never leaves a half-written, corrupt checkpoint
        // that would poison the next resume attempt.
        let data = try JSONEncoder().encode(clips)
        try data.write(to: dataset.checkpoint(root: root), options: .atomic)
    }

    private static func finalizeManifest(
        _ clips: [EvalClip], dataset: Dataset, root: URL, samplingMethod: String, seed: Int?,
        requestedCount: Int, totalSourceRows: Int?
    ) throws {
        let manifest = DatasetManifest(
            dataset: dataset.source.dataset, config: dataset.source.config, split: dataset.source.split,
            license: dataset.license, samplingSeed: seed, samplingMethod: samplingMethod,
            requestedCount: requestedCount, totalSourceRows: totalSourceRows, clips: clips)
        // Keep the plain `[EvalClip]` manifest.json format the rest of the harness reads,
        // and additionally write a `manifest.provenance.json` with full sampling/license detail.
        try JSONEncoder().encode(clips).write(to: dataset.manifest(root: root), options: .atomic)
        let provenanceURL = dataset.directory(root: root).appendingPathComponent("manifest.provenance.json")
        try JSONEncoder().encode(manifest).write(to: provenanceURL, options: .atomic)
        try? FileManager.default.removeItem(at: dataset.checkpoint(root: root))
    }

    // MARK: Networking with retry/backoff

    /// Retries on 429 and 5xx with exponential backoff plus jitter, honoring `Retry-After` when
    /// the server sends one. Other failures (4xx besides 429, transport errors after retries
    /// exhausted) are thrown so the caller can record a specific failure reason.
    private static func fetchRowsWithBackoff(_ dataset: Dataset, offset: Int, length: Int) async throws -> [[String: Any]] {
        try await fetchRows(source: dataset.source, offset: offset, length: length)
    }

    /// One page of rows from any datasets-server split (used directly by samplers that read more
    /// than one split, e.g. `EdAccAccents`).
    static func fetchRows(
        source: (dataset: String, config: String, split: String), offset: Int, length: Int
    ) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://datasets-server.huggingface.co/rows")!
        components.queryItems = [
            URLQueryItem(name: "dataset", value: source.dataset),
            URLQueryItem(name: "config", value: source.config),
            URLQueryItem(name: "split", value: source.split),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "length", value: String(length)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 120
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response, _) = try await sendWithBackoff(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw EvalError.download("\(source.dataset): HTTP \(status) \(body)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["rows"] as? [[String: Any]] ?? []).compactMap { $0["row"] as? [String: Any] }
    }

    static func downloadFileWithBackoff(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response, _) = try await sendWithBackoff(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EvalError.download("audio fetch HTTP \(status)")
        }
        try data.write(to: destination, options: .atomic)
    }

    private static let maxRetries = 6

    /// Sends a request, retrying with exponential backoff + jitter on 429/5xx or transient
    /// transport errors. Returns the final response even if it never succeeded (caller checks
    /// status), plus a `retryable` flag for callers that want to distinguish "gave up after
    /// retries" from "succeeded"/"non-retryable error".
    private static func sendWithBackoff(_ request: URLRequest) async throws -> (Data, URLResponse, retryable: Bool) {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                        if attempt == maxRetries - 1 { return (data, response, true) }
                        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                        try await Task.sleep(nanoseconds: UInt64((retryAfter ?? backoffSeconds(attempt)) * 1_000_000_000))
                        continue
                    }
                }
                return (data, response, false)
            } catch {
                lastError = error
                if attempt == maxRetries - 1 { throw error }
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds(attempt) * 1_000_000_000))
            }
        }
        throw lastError ?? EvalError.download("retries exhausted")
    }

    /// Exponential backoff (base 1s, doubling, capped at 60s) with up to 30% random jitter so
    /// concurrent retries don't all land on the server at once.
    static func backoffSeconds(_ attempt: Int) -> Double {
        let base = min(60.0, pow(2.0, Double(attempt)))
        let jitter = Double.random(in: 0...(base * 0.3))
        return base + jitter
    }
}

/// Small, fast, fixed-seed PRNG (SplitMix64) used for reproducible sampling — no dependency on
/// platform-specific `Random` seeding behavior.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum EvalError: LocalizedError {
    case download(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .download(let message): "Download failed: \(message)"
        case .missing(let message): message
        }
    }
}
