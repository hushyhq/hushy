import Foundation

/// Every EdAcc accent group, not just Indian vs US — the data behind an accent-parity claim.
///
/// EdAcc (`edinburghcstr/edacc`, CC-BY-4.0) is conversational English from ~120 speakers labelled
/// with a self-described accent. Both published splits are used (`validation` + `test`): nothing is
/// tuned on them, and pooling roughly doubles the speakers per accent, which matters more here than
/// keeping a held-out split. Groups need at least `minClips` usable utterances; "Don't know" is not
/// an accent and is dropped. Within a group, clips are taken round-robin across speakers (each
/// speaker's utterances shuffled with a fixed seed) so one talkative speaker cannot dominate.
///
/// The sampled manifest lives at `Evals/data/edacc-all-accents/manifest.json` and records the
/// speaker of every clip, so `AccentParity` can report how many people stand behind each number.
enum EdAccAccents {
    static let folderName = "edacc-all-accents"
    static let splits = ["validation", "test"]
    static let excludedLabels: Set<String> = ["Don't know"]

    /// One scanned EdAcc utterance (audio not yet downloaded).
    struct Row: Equatable {
        let split: String
        let index: Int
        let speaker: String
        let accent: String
        let text: String
        let audioURL: String
    }

    static func folder(root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    /// Loads the sampled manifest, downloading it first if it is not on disk yet.
    static func loadOrDownload(perGroup: Int, minClips: Int, seed: UInt64, root: URL) async throws -> [EvalClip] {
        let manifest = folder(root: root).appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            return try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifest))
        }
        print("Scanning EdAcc (\(splits.joined(separator: " + "))) for accent labels…")
        var rows: [Row] = []
        for split in splits { rows += try await scan(split: split) }
        let chosen = select(rows, perGroup: perGroup, minClips: minClips, seed: seed)
        print("  \(rows.count) utterances scanned; sampling \(chosen.count) across \(Set(chosen.map(\.accent)).count) accents")
        let clips = try await download(chosen, root: root)
        try FileManager.default.createDirectory(at: folder(root: root), withIntermediateDirectories: true)
        try JSONEncoder().encode(clips).write(to: manifest, options: .atomic)
        return clips
    }

    // MARK: Selection (pure, tested)

    /// A reference with segment tags removed; empty when nothing scorable is left.
    static func scorableText(_ text: String) -> String {
        guard !text.contains("IGNORE_TIME_SEGMENT") else { return "" }
        return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groups rows by accent, keeps groups with ≥ `minClips` scorable rows, and takes up to
    /// `perGroup` from each, round-robin over speakers (sorted by id) with each speaker's rows in a
    /// seeded shuffle. Deterministic for a given input and seed.
    static func select(_ rows: [Row], perGroup: Int, minClips: Int, seed: UInt64) -> [Row] {
        let usable = rows.filter { !excludedLabels.contains($0.accent) && !scorableText($0.text).isEmpty }
        let byAccent = Dictionary(grouping: usable, by: \.accent)
        var chosen: [Row] = []
        for accent in byAccent.keys.sorted() {
            guard let group = byAccent[accent], group.count >= minClips else { continue }
            var generator = SplitMix64(seed: seed)
            let bySpeaker = Dictionary(grouping: group, by: \.speaker)
            var queues = bySpeaker.keys.sorted().map { speaker in
                shuffled(bySpeaker[speaker] ?? [], using: &generator)
            }
            var taken = 0
            while taken < perGroup, queues.contains(where: { !$0.isEmpty }) {
                for index in queues.indices where taken < perGroup && !queues[index].isEmpty {
                    chosen.append(queues[index].removeFirst())
                    taken += 1
                }
            }
        }
        return chosen
    }

    /// Fisher–Yates with the eval's own seeded PRNG (stable across platforms and Swift versions).
    static func shuffled(_ rows: [Row], using generator: inout SplitMix64) -> [Row] {
        var result = rows.sorted { ($0.split, $0.index) < ($1.split, $1.index) }
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            result.swapAt(index, other)
        }
        return result
    }

    // MARK: Network

    private static func scan(split: String) async throws -> [Row] {
        var rows: [Row] = []
        var offset = 0
        let source = (dataset: "edinburghcstr/edacc", config: "default", split: split)
        while true {
            let page = try await patientFetch(source: source, offset: offset)
            if page.isEmpty { break }
            for (position, row) in page.enumerated() {
                guard let speaker = row["speaker"] as? String, let accent = row["accent"] as? String,
                      let text = row["text"] as? String,
                      let audio = (row["audio"] as? [[String: Any]])?.first ?? (row["audio"] as? [String: Any]),
                      let url = audio["src"] as? String
                else { continue }
                rows.append(Row(split: split, index: offset + position, speaker: speaker, accent: accent,
                                text: text, audioURL: url))
            }
            offset += page.count
        }
        return rows
    }

    /// The datasets-server rate-limits `/rows` per IP (HTTP 429 even after `Downloader`'s own
    /// backoff), so a 186-page scan paces itself and, when throttled, waits a minute and tries again.
    private static func patientFetch(
        source: (dataset: String, config: String, split: String), offset: Int
    ) async throws -> [[String: Any]] {
        var attempt = 0
        while true {
            do {
                let page = try await Downloader.fetchRows(source: source, offset: offset, length: Downloader.pageSize)
                try await Task.sleep(nanoseconds: 500_000_000)
                return page
            } catch {
                attempt += 1
                guard attempt < 5 else { throw error }
                print("  throttled at \(source.split) offset \(offset); waiting 60 s (attempt \(attempt)/5)")
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// Downloads audio for the chosen rows, a few at a time; rows that fail are dropped and counted.
    private static func download(_ rows: [Row], root: URL) async throws -> [EvalClip] {
        let directory = folder(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var clips: [EvalClip] = []
        var failed = 0
        let width = 4
        for start in stride(from: 0, to: rows.count, by: width) {
            let batch = Array(rows[start..<min(start + width, rows.count)])
            let results = await withTaskGroup(of: EvalClip?.self) { group in
                for row in batch {
                    group.addTask { await fetch(row, into: directory) }
                }
                var collected: [EvalClip] = []
                for await clip in group { if let clip { collected.append(clip) } }
                return collected
            }
            failed += batch.count - results.count
            clips += results
            if start % 300 == 0 { print("  edacc-all-accents: \(clips.count)/\(rows.count)") }
        }
        if failed > 0 { print("  ! \(failed) EdAcc clips failed to download and were skipped") }
        return clips.sorted { $0.id < $1.id }
    }

    private static func fetch(_ row: Row, into directory: URL) async -> EvalClip? {
        guard let url = URL(string: row.audioURL) else { return nil }
        let id = String(format: "edacc-%@-%05d", row.split, row.index)
        let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let destination = directory.appendingPathComponent("\(id).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            do { try await Downloader.downloadFileWithBackoff(url, to: destination) } catch { return nil }
        }
        return EvalClip(id: id, audioPath: destination.path, reference: scorableText(row.text), fluentReference: nil,
                        group: row.accent, sourceRowIndex: row.index, speaker: row.speaker)
    }
}
