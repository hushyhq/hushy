@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// Local import of a Mozilla Common Voice release the user has downloaded and extracted by
/// hand (login required on Mozilla Data Collective, so this cannot be fetched automatically
/// like the Hugging Face datasets in `Datasets.swift`). Handles both:
///   - `commonvoice-spontaneous`: Spontaneous Speech 5.0 English (`ss-corpus-en.tsv`)
///   - `commonvoice-scripted`: Scripted 27.0 English (`validated.tsv`/`test.tsv`, standard CV layout)
/// The TSV column names differ slightly release to release, so parsing is tolerant: it looks
/// for the first present name in a list of candidates per field and prints what it found.
enum CommonVoiceImport {
    struct Row {
        let clientId: String?
        let audioFile: String
        let transcript: String
        let accent: String?
        let age: String?
        let gender: String?
        let split: String?
        let reported: Bool
    }

    /// Which manifest/target this import produces.
    enum Kind: String {
        case spontaneous = "commonvoice-spontaneous"
        case scripted = "commonvoice-scripted"
    }

    /// `murmur-eval import-commonvoice --path <folder-or-archive> [--kind spontaneous|scripted]
    ///   [--limit N] [--per-speaker N] [--seed N]`
    static func run(_ args: Arguments) async throws {
        guard let inputPath = args.string("path") else {
            throw EvalError.missing("usage: murmur-eval import-commonvoice --path <extracted folder or .tar.gz> [--kind spontaneous|scripted] [--limit N] [--per-speaker N]")
        }
        let kind = Kind(rawValue: "commonvoice-" + (args.string("kind") ?? "spontaneous"))
            ?? Kind(rawValue: args.string("kind") ?? "") ?? .spontaneous
        let limit = args.int("limit") ?? 500
        let perSpeaker = args.int("per-speaker") ?? 3
        let seed = UInt64(args.int("seed") ?? 42)

        let folder = try extractIfNeeded(inputPath)
        let (tsvURL, audioRoot) = try locateFiles(in: folder, kind: kind)
        print("Reading \(tsvURL.lastPathComponent)")
        let (header, records) = try TSV.parse(tsvURL)
        print("  columns found: \(header.joined(separator: ", "))")

        let columns = try ResolvedColumns(header: header, kind: kind)
        print("  using: audio=\(columns.audioFile) transcript=\(columns.transcript)"
            + (columns.accent.map { " accent=\($0)" } ?? " accent=<none>")
            + (columns.clientId.map { " speaker=\($0)" } ?? " speaker=<none>")
            + (columns.split.map { " split=\($0)" } ?? " split=<none>"))

        let reportedFiles = (try? loadReportedAudioFiles(in: folder)) ?? []
        if !reportedFiles.isEmpty { print("  excluding \(reportedFiles.count) reported clip(s)") }

        let rows = records.compactMap { record -> Row? in
            columns.row(from: record, reportedFiles: reportedFiles)
        }
        print("  \(rows.count)/\(records.count) rows usable (validated transcript + audio file present, not reported)")

        let eligible: [Row]
        switch kind {
        case .spontaneous:
            // Held out from any future fine-tuning pool: dev+test only, never train.
            eligible = rows.filter { $0.split == "dev" || $0.split == "test" }
            print("  \(eligible.count) rows in dev+test (held-out eval pool, excluding train)")
        case .scripted:
            eligible = rows.filter { $0.split == nil || $0.split == "test" }
        }
        guard !eligible.isEmpty else {
            throw EvalError.missing("No usable rows found — check --kind and the extracted folder layout")
        }

        let sample = balancedSample(eligible, limit: limit, perSpeaker: perSpeaker, seed: seed)
        print("  sampled \(sample.count) clips (balanced by accent where present, capped at \(perSpeaker)/speaker)")

        let destinationRoot = Paths.data.appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        var clips: [EvalClip] = []
        var converted = 0
        var failed = 0
        for (index, row) in sample.enumerated() {
            let sourceAudio = audioRoot.appendingPathComponent(row.audioFile)
            guard FileManager.default.fileExists(atPath: sourceAudio.path) else {
                failed += 1
                continue
            }
            let id = String(format: "%@-%05d", kind.rawValue, index)
            let destination = destinationRoot.appendingPathComponent("\(id).wav")
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let samples = try AudioConverter().resampleAudioFile(sourceAudio)
                    try EvalWAV.write(samples, to: destination)
                }
                clips.append(EvalClip(
                    id: id, audioPath: destination.path, reference: normalizeTranscript(row.transcript),
                    fluentReference: nil, group: row.accent))
                converted += 1
            } catch {
                failed += 1
            }
            if (index + 1) % 50 == 0 { print("  converted \(converted)/\(sample.count) (\(failed) failed)") }
        }

        let manifest = DatasetManifest(
            dataset: "Mozilla Common Voice (\(kind == .spontaneous ? "Spontaneous Speech 5.0" : "Scripted 27.0")) English",
            config: kind == .spontaneous ? "spontaneous-speech-5.0-en" : "scripted-27.0-en",
            split: kind == .spontaneous ? "dev+test (held out from train)" : "test",
            license: "CC0-1.0 (Mozilla Common Voice)",
            samplingSeed: Int(seed), samplingMethod: "balanced-by-accent-speaker-capped",
            requestedCount: limit, totalSourceRows: records.count, clips: clips)
        try JSONEncoder().encode(clips).write(
            to: destinationRoot.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder().encode(manifest).write(
            to: destinationRoot.appendingPathComponent("manifest.provenance.json"), options: .atomic)

        print("Imported \(converted)/\(sample.count) clips to \(destinationRoot.path) (\(failed) failed/missing)")
    }

    /// Strips bracketed disfluency/quality tags (`[disfluency]`, `<noise>`, `[um]`, etc.) that
    /// Common Voice's disfluency/quality tagging inserts into transcripts, the same way the
    /// harness already strips angle-bracket segment tags before scoring (see `Runners.asr`).
    static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deterministic, fixed-seed balanced sample: caps clips per speaker (so a handful of
    /// prolific speakers can't dominate) and, when an accent label is present on some rows,
    /// spreads the sample across accent groups round-robin so no single accent dominates either.
    static func balancedSample(_ rows: [Row], limit: Int, perSpeaker: Int, seed: UInt64) -> [Row] {
        var generator = SplitMix64(seed: seed)
        // Deterministic shuffle so repeated runs with the same seed give the same sample.
        var indexed = Array(rows.enumerated())
        for i in stride(from: indexed.count - 1, to: 0, by: -1) {
            let j = Int(generator.next() % UInt64(i + 1))
            indexed.swapAt(i, j)
        }
        let shuffled = indexed.map(\.element)

        var perSpeakerCount: [String: Int] = [:]
        let speakerCapped = shuffled.filter { row in
            guard let speaker = row.clientId else { return true }
            let count = perSpeakerCount[speaker, default: 0]
            guard count < perSpeaker else { return false }
            perSpeakerCount[speaker] = count + 1
            return true
        }

        let hasAccents = speakerCapped.contains { ($0.accent?.isEmpty == false) }
        guard hasAccents else { return Array(speakerCapped.prefix(limit)) }

        // Round-robin across accent groups (rows with no accent form their own "unknown" group)
        // so the sample doesn't collapse to whichever accent happens to be most common.
        let groups = Dictionary(grouping: speakerCapped) { $0.accent?.isEmpty == false ? $0.accent! : "unspecified" }
        var queues = groups.mapValues { $0.makeIterator() }
        let groupNames = groups.keys.sorted()
        var result: [Row] = []
        var exhausted = Set<String>()
        while result.count < limit, exhausted.count < groupNames.count {
            for name in groupNames {
                guard result.count < limit else { break }
                if var iterator = queues[name] {
                    if let next = iterator.next() {
                        result.append(next)
                        queues[name] = iterator
                    } else {
                        exhausted.insert(name)
                    }
                }
            }
        }
        return result
    }

    // MARK: File location

    private static func extractIfNeeded(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw EvalError.missing("Path does not exist: \(path)")
        }
        if isDirectory.boolValue { return url }
        guard url.pathExtension == "gz" || url.lastPathComponent.hasSuffix(".tar.gz") else {
            throw EvalError.missing("Expected a folder or a .tar.gz archive, got \(url.lastPathComponent)")
        }
        let destination = Paths.data.appendingPathComponent(
            "commonvoice-extract-\(url.deletingPathExtension().deletingPathExtension().lastPathComponent)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        print("Extracting \(url.lastPathComponent) to \(destination.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", url.path, "-C", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EvalError.missing("tar extraction failed for \(path)") }
        return destination
    }

    /// Common Voice releases vary in exact file naming (`ss-corpus-en.tsv` for the spontaneous
    /// release, `validated.tsv`/`test.tsv` for standard scripted releases); look for whichever
    /// is present rather than hardcoding one name.
    private static func locateFiles(in folder: URL, kind: Kind) throws -> (tsv: URL, audioRoot: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { throw EvalError.missing("Could not read \(folder.path)") }
        let candidateNames: [String]
        switch kind {
        case .spontaneous: candidateNames = ["ss-corpus-en.tsv"]
        case .scripted: candidateNames = ["test.tsv", "validated.tsv", "train.tsv"]
        }
        var tsvURL: URL?
        for name in candidateNames {
            if let match = contents.first(where: { $0.lastPathComponent == name }) { tsvURL = match; break }
        }
        if tsvURL == nil {
            // Fall back to any .tsv file whose name suggests it's the right one.
            tsvURL = contents.first { $0.pathExtension == "tsv" && !$0.lastPathComponent.contains("reported") }
        }
        guard let tsv = tsvURL else {
            throw EvalError.missing("No usable .tsv found in \(folder.path) (looked for \(candidateNames.joined(separator: ", ")))")
        }
        let audioRoot = ["audios", "clips"]
            .map { folder.appendingPathComponent($0, isDirectory: true) }
            .first { fm.fileExists(atPath: $0.path) } ?? folder
        return (tsv, audioRoot)
    }

    private static func loadReportedAudioFiles(in folder: URL) throws -> Set<String> {
        let reportedURL = folder.appendingPathComponent("ss-reported-audios-en.tsv")
        guard FileManager.default.fileExists(atPath: reportedURL.path) else { return [] }
        let (header, records) = try TSV.parse(reportedURL)
        guard let audioColumn = ["audio_file", "path", "filename"].first(where: header.contains) else { return [] }
        let index = header.firstIndex(of: audioColumn)!
        return Set(records.compactMap { $0.count > index ? $0[index] : nil })
    }
}

/// Resolves which column index to use for each logical field, tolerant of naming differences
/// between Common Voice releases, and turns a raw record into a `CommonVoiceImport.Row`.
struct ResolvedColumns {
    let audioFile: String
    let transcript: String
    let accent: String?
    let age: String?
    let gender: String?
    let clientId: String?
    let split: String?
    private let header: [String]

    init(header: [String], kind: CommonVoiceImport.Kind) throws {
        self.header = header
        func find(_ candidates: [String]) -> String? { candidates.first(where: header.contains) }
        guard let audio = find(["audio_file", "path", "filename"]) else {
            throw EvalError.missing("Could not find an audio filename column in \(header.joined(separator: ", "))")
        }
        guard let transcript = find(["transcription", "sentence", "text", "transcript"]) else {
            throw EvalError.missing("Could not find a transcript column in \(header.joined(separator: ", "))")
        }
        self.audioFile = audio
        self.transcript = transcript
        self.accent = find(["accents", "accent"])
        self.age = find(["age"])
        self.gender = find(["gender"])
        self.clientId = find(["client_id", "speaker_id"])
        self.split = find(["split"])
    }

    private func value(_ column: String?, in record: [String]) -> String? {
        guard let column, let index = header.firstIndex(of: column), index < record.count else { return nil }
        let value = record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func row(from record: [String], reportedFiles: Set<String>) -> CommonVoiceImport.Row? {
        guard let audioValue = value(audioFile, in: record), let transcriptValue = value(transcript, in: record) else {
            return nil
        }
        guard !reportedFiles.contains(audioValue) else { return nil }
        return CommonVoiceImport.Row(
            clientId: value(clientId, in: record), audioFile: audioValue, transcript: transcriptValue,
            accent: value(accent, in: record), age: value(age, in: record), gender: value(gender, in: record),
            split: value(split, in: record), reported: false)
    }
}

/// Minimal, dependency-free TSV parser: no quoting/escaping (Common Voice TSVs use bare tabs and
/// newlines within fields are not expected), tolerant of a trailing blank line.
enum TSV {
    static func parse(_ url: URL) throws -> (header: [String], records: [[String]]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard let headerLine = lines.first else { return ([], []) }
        let header = headerLine.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "\t")
        let records = lines.dropFirst().map { line -> [String] in
            line.hasSuffix("\r") ? String(line.dropLast()).components(separatedBy: "\t") : line.components(separatedBy: "\t")
        }
        return (header, records)
    }
}
