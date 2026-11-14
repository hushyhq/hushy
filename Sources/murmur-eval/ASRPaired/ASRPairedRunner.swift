import AVFoundation
import CryptoKit
import Foundation
import FluidAudio
import MurmurCore

/// Local paired Parakeet/candidate report. This is an eval harness, not a live dictation path.
enum ASRPairedRunner {
    static func run(_ args: Arguments) async throws {
        guard let operation = args.positional.first else { throw usage() }
        switch operation {
        case "prepare": try prepare(args)
        case "compare": try await compare(args)
        default: throw usage()
        }
    }

    private static func prepare(_ args: Arguments) throws {
        guard let casesPath = args.string("cases"), let outPath = args.string("out-dir") else { throw usage() }
        let sourceURL = URL(fileURLWithPath: casesPath).standardizedFileURL
        let root = URL(fileURLWithPath: outPath, isDirectory: true).standardizedFileURL
        let input = try JSONDecoder().decode(ASRPairedCases.self, from: Data(contentsOf: sourceURL))
        guard input.schema_version == 1 else { throw ASRPairedValidationError.invalid("dev cases schema_version must be 1") }
        guard !input.clips.isEmpty else { throw ASRPairedValidationError.invalid("dev cases must contain at least one clip") }
        let ids = input.clips.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else { throw ASRPairedValidationError.invalid("clip IDs must be non-empty and unique") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        var clips: [ASRPairedManifestClip] = []
        for (index, item) in input.clips.enumerated() {
            try ASRPairedScoring.validateReference(item.reference, category: item.category, clipID: item.id)
            let wav = audioDir.appendingPathComponent(String(format: "%03d-%@.wav", index + 1, safe(item.id)))
            let source: URL
            if let path = item.audio_path, !path.isEmpty {
                source = URL(fileURLWithPath: path, relativeTo: sourceURL.deletingLastPathComponent()).standardizedFileURL
                guard FileManager.default.fileExists(atPath: source.path) else { throw ASRPairedValidationError.invalid("audio_path not found for \(item.id): \(source.path)") }
                try SealedEvalGuard.assertTuningSafe(source, purpose: "asr-paired input audio")
                let samples = try AudioConverter().resampleAudioFile(source)
                guard !samples.isEmpty else { throw ASRPairedValidationError.invalid("empty audio input for \(item.id)") }
                try EvalWAV.write(LoudnessNormalizer.normalize(samples), to: wav)
            } else {
                throw ASRPairedValidationError.invalid("clip \(item.id) has no audio_path; run scripts/asr-paired/synthesize.py first")
            }
            guard (try Data(contentsOf: wav)).count > 44 else { throw ASRPairedValidationError.invalid("empty or invalid audio for \(item.id)") }
            clips.append(ASRPairedManifestClip(
                id: item.id, audio_path: wav.path, audio_sha256: sha256(try Data(contentsOf: wav)),
                reference: item.reference, cleaned_reference: item.cleaned_reference,
                group: item.group, category: item.category, critical_terms: item.critical_terms))
        }
        let manifest = ASRPairedManifest(schema_version: 1, clips: clips)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        print("Prepared \(clips.count) clips → \(root.appendingPathComponent("manifest.json").path)")
    }

    private static func compare(_ args: Arguments) async throws {
        guard let manifestPath = args.string("manifest"), let resultPath = args.string("candidate-results"),
              let reportPath = args.string("report") else { throw usage() }
        let backend = args.string("backend") ?? "local"
        guard backend == "mlx" || backend == "none" || (backend == "remote" && args.flag("allow-remote-cleanup")) else {
            throw ASRPairedValidationError.invalid("paired cleanup requires --backend mlx with --mlx-model, --mlx-prompt compact, and --clean-gate always (or --backend none for unscored plumbing); remote requires explicit opt-in")
        }
        if backend == "mlx" {
            guard args.string("mlx-model") != nil, args.string("mlx-prompt") == "compact", args.string("clean-gate") == "always" else {
                throw ASRPairedValidationError.invalid("frozen cleanup comparison requires --backend mlx --mlx-model <dir> --mlx-prompt compact --clean-gate always")
            }
        }
        guard backend != "remote" || args.flag("allow-remote-cleanup") else {
            throw ASRPairedValidationError.invalid("remote cleanup is disabled for paired comparisons; pass --allow-remote-cleanup to opt in")
        }
        let manifest = try JSONDecoder().decode(ASRPairedManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let lines = try String(contentsOfFile: resultPath, encoding: .utf8).split(whereSeparator: \.isNewline).map { line in
            try JSONDecoder().decode(ASRPairedCandidateLine.self, from: Data(line.utf8))
        }
        try ASRPairedScoring.validate(manifest: manifest, candidates: lines, requireAssetHashes: backend == "mlx")
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.clip_id, $0) })
        let modelName = args.string("model") ?? "ultra+guard"
        guard let engine = try await Engine.load(named: modelName) else { throw ASRPairedValidationError.invalid("unknown --model \(modelName) (expected v2|v3|ultra|ultra+guard)") }
        let cleaner = args.makeCleaner()
        cleaner.prewarm()
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: args.cleanupLevel))
        var rows: [ReportClip] = []
        for clip in manifest.clips {
            let audioURL = resolveAudioPath(clip.audio_path, manifestPath: manifestPath)
            let audioData = try Data(contentsOf: audioURL)
            guard sha256(audioData) == clip.audio_sha256 else { throw ASRPairedValidationError.invalid("prepared audio hash changed for \(clip.id)") }
            try SealedEvalGuard.assertTuningSafe(audioURL, purpose: "asr-paired prepared audio")
            let samples = try AudioConverter().resampleAudioFile(audioURL)
            var baselineText = "", baselineSeconds = 0.0, baselineError: String?
            do {
                let start = ContinuousClock.now
                baselineText = try await engine.transcribe(samples).0
                baselineSeconds = elapsed(start)
            } catch { baselineError = error.localizedDescription }
            guard let candidate = byID[clip.id] else { throw ASRPairedValidationError.invalid("missing candidate clip \(clip.id)") }
            let candidateOK = candidate.status == "ok"
            let candidateText = candidateOK ? candidate.text : ""
            let candidateDiagnosticText = candidate.text
            let candidateFailure = candidateOK ? candidate.error : (candidate.error ?? "candidate status=error")
            let baselineClean = await pipeline.clean(baselineText, settings: settings, strategy: args.strategy)
            let candidateClean = await pipeline.clean(candidateText, settings: settings, strategy: args.strategy)
            rows.append(ReportClip(
                id: clip.id, group: clip.group, category: clip.category, reference: clip.reference,
                baseline: scorer(clip.reference, baselineText, baselineError), candidate: scorer(clip.reference, candidateText, candidateFailure, failed: !candidateOK),
                cleanedReference: clip.cleaned_reference,
                baselineCleanWER: clip.cleaned_reference.flatMap { ASRPairedScoring.wer(reference: $0, hypothesis: baselineClean.text).value },
                candidateCleanWER: clip.cleaned_reference.flatMap { ASRPairedScoring.wer(reference: $0, hypothesis: candidateClean.text).value },
                baselineCleanExact: clip.cleaned_reference.map { $0 == baselineClean.text },
                candidateCleanExact: clip.cleaned_reference.map { candidateOK && $0 == candidateClean.text },
                criticalTerms: (clip.critical_terms ?? []).map { TermScore(term: $0,
                    baselineRawPreserved: ASRPairedScoring.preserves($0, in: baselineText), candidateRawPreserved: candidateOK && ASRPairedScoring.preserves($0, in: candidateText),
                    baselineFinalPreserved: ASRPairedScoring.preserves($0, in: baselineClean.text), candidateFinalPreserved: candidateOK && ASRPairedScoring.preserves($0, in: candidateClean.text)) },
                silence: ASRPairedScoring.isSilence(clip),
                baselineSeconds: baselineSeconds, baselineError: baselineError,
                candidateRecognitionSeconds: candidate.recognition_seconds, candidateLoadSeconds: candidate.load_seconds,
                candidateError: candidateFailure, baselineRaw: baselineText, candidateRaw: candidateDiagnosticText,
                baselineRules: await pipeline.clean(baselineText, settings: settings, strategy: .rules).text,
                baselineFinal: baselineClean.text, candidateRules: await pipeline.clean(candidateText, settings: settings, strategy: .rules).text,
                candidateFinal: candidateClean.text, baselineUsedModel: baselineClean.usedModel, candidateUsedModel: candidateClean.usedModel,
                baselineRejection: baselineClean.rejection, candidateRejection: candidateClean.rejection,
                baselineCleanupSeconds: baselineClean.timings.cleanupMs / 1000, candidateCleanupSeconds: candidateClean.timings.cleanupMs / 1000))
        }
        let baselineIDs = "FluidAudio Engine / \(modelName); Package.resolved sha256 \(packageResolutionHash()); FluidAudio model asset hashes unavailable from the current adapter"
        let modelIDs = Set(lines.map { "\($0.model_id)@\($0.model_revision) / \($0.runtime_revision)" })
        let cleanupDirectory = args.string("mlx-model").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let cleanupFileHashes = try cleanupDirectory.map(fileHashes(in:)) ?? [:]
        let reportURL = URL(fileURLWithPath: reportPath).standardizedFileURL
        try assertSafeReportTarget(reportURL, inputFiles: [URL(fileURLWithPath: manifestPath), URL(fileURLWithPath: resultPath)]
            + manifest.clips.map { resolveAudioPath($0.audio_path, manifestPath: manifestPath) }, protectedDirectory: cleanupDirectory)
        let report = Report(schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
            baseline: "Parakeet \(modelName)", baselineRevision: baselineIDs,
            candidateIdentities: modelIDs.sorted(),
            candidateAssetHashes: ASRPairedScoring.candidateAssetReport(lines),
            candidateRuntimeSourceSHA256: ASRPairedScoring.candidateRuntimeSourceHash(lines),
            cleanupModelDirectory: cleanupDirectory?.path, cleanupModelFileSHA256: cleanupFileHashes,
            cleanupModelComparison: backend == "mlx",
            manifestSHA256: sha256(try Data(contentsOf: URL(fileURLWithPath: manifestPath))),
            cleanup: "DictationPipeline.clean; strategy \(args.strategy.rawValue); level \(args.cleanupLevel.rawValue); backend \(backend); mlx-model \(args.string("mlx-model") ?? "none"); mlx-prompt \(args.string("mlx-prompt") ?? "n/a"); clean-gate \(args.string("clean-gate") ?? "n/a")",
            timingNote: "Sequential batch inference and cleanup timings; not key-release, microphone, or paste latency. Cleanup is measured baseline-first and shares process caches.", clips: rows,
            summary: Summary(baseline: summarize(rows.map(\.baseline)), candidate: summarize(rows.map(\.candidate)),
                baselineInferenceP50: percentile(rows.filter { $0.baseline.error == nil }.map(\.baselineSeconds), 0.5),
                baselineInferenceP95: percentile(rows.filter { $0.baseline.error == nil }.map(\.baselineSeconds), 0.95),
                candidateInferenceP50: percentile(rows.filter { $0.candidate.error == nil }.map(\.candidateRecognitionSeconds), 0.5),
                candidateInferenceP95: percentile(rows.filter { $0.candidate.error == nil }.map(\.candidateRecognitionSeconds), 0.95),
                candidateLoadP50: percentile(rows.map(\.candidateLoadSeconds), 0.5), candidateLoadP95: percentile(rows.map(\.candidateLoadSeconds), 0.95),
                baselineCleanupP50: percentile(rows.map(\.baselineCleanupSeconds), 0.5), baselineCleanupP95: percentile(rows.map(\.baselineCleanupSeconds), 0.95),
                candidateCleanupP50: percentile(rows.map(\.candidateCleanupSeconds), 0.5), candidateCleanupP95: percentile(rows.map(\.candidateCleanupSeconds), 0.95),
                baselineErrors: rows.filter { $0.baseline.error != nil }.count, candidateErrors: rows.filter { $0.candidate.error != nil }.count,
                silenceCount: rows.filter(\.silence).count, baselineSilenceHallucinations: rows.filter { $0.silence && $0.baselineError == nil && !$0.baselineRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
                candidateSilenceHallucinations: rows.filter { $0.silence && $0.candidate.error == nil && !$0.candidateRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
                strata: strata(rows), pairedRawSpeech: pairedCounts(rows)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("Paired ASR report: \(reportPath) · \(rows.count) clips")
    }

    private static func scorer(_ reference: String, _ text: String, _ error: String?, failed: Bool = false) -> Score {
        let wer = ASRPairedScoring.wer(reference: reference, hypothesis: failed ? "" : text)
        return Score(errors: wer.errors, referenceWords: wer.referenceWords, wer: wer.value, error: error)
    }
    private static func summarize(_ scores: [Score]) -> Aggregate {
        let denom = scores.reduce(0) { $0 + $1.referenceWords }
        return Aggregate(wer: denom == 0 ? nil : Double(scores.reduce(0) { $0 + $1.errors }) / Double(denom),
            errors: scores.reduce(0) { $0 + $1.errors }, referenceWords: denom, clipCount: scores.count, errorCount: scores.filter { $0.error != nil }.count)
    }
    private static func strata(_ rows: [ReportClip]) -> [Stratum] {
        let groupKeys = Set(rows.compactMap(\.group)).sorted().map { ("group", $0) }
        let categoryKeys = Set(rows.compactMap(\.category)).sorted().map { ("category", $0) }
        return (groupKeys + categoryKeys).map { dimension, value in
            let selected = rows.filter { dimension == "group" ? $0.group == value : $0.category == value }
            return Stratum(dimension: dimension, value: value,
                baseline: summarize(selected.map(\.baseline)), candidate: summarize(selected.map(\.candidate)))
        }
    }
    private static func pairedCounts(_ rows: [ReportClip]) -> PairedCounts {
        let pairs = rows.filter { !$0.silence && $0.baseline.error == nil && $0.candidate.error == nil }
        return PairedCounts(clips: pairs.count,
            wins: pairs.filter { $0.candidate.errors < $0.baseline.errors }.count,
            ties: pairs.filter { $0.candidate.errors == $0.baseline.errors }.count,
            losses: pairs.filter { $0.candidate.errors > $0.baseline.errors }.count)
    }
    private static func percentile(_ input: [Double], _ p: Double) -> Double? {
        let values = input.sorted(); guard !values.isEmpty else { return nil }
        return values[Int((Double(values.count - 1) * p).rounded(.up))]
    }
    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now); return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func packageResolutionHash() -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Package.resolved")
        return (try? Data(contentsOf: url)).map(sha256) ?? "unavailable"
    }
    static func resolveAudioPath(_ path: String, manifestPath: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return URL(fileURLWithPath: manifestPath).deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
    static func assertSafeReportTarget(_ reportURL: URL, inputFiles: [URL], protectedDirectory: URL?) throws {
        let reportPath = reportURL.standardizedFileURL.resolvingSymlinksInPath().path
        let sameAsInput = inputFiles.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == reportPath }
        let directoryPath = protectedDirectory?.standardizedFileURL.resolvingSymlinksInPath().path
        let insideModel = directoryPath.map { reportPath == $0 || reportPath.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ?? false
        guard !sameAsInput, !insideModel else {
            throw ASRPairedValidationError.invalid("report path must not overwrite an input or be inside the cleanup model directory")
        }
    }
    private static func fileHashes(in directory: URL) throws -> [String: String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ASRPairedValidationError.invalid("cleanup model directory not found: \(directory.path)")
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw ASRPairedValidationError.invalid("cannot enumerate cleanup model directory: \(directory.path)")
        }
        var hashes: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ASRPairedValidationError.invalid("cleanup model directory contains a symlink that cannot be fingerprinted safely: \(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            hashes[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard !hashes.isEmpty else { throw ASRPairedValidationError.invalid("cleanup model directory contains no regular files") }
        return hashes
    }
    private static func safe(_ text: String) -> String { String(text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(60)) }
    private static func usage() -> EvalError { .missing("usage: murmur-eval asr-paired prepare --cases <dev.json> --out-dir <scratch> | compare --manifest <file> --candidate-results <JSONL> --model ultra+guard --backend mlx --mlx-model <dir> --mlx-prompt compact --clean-gate always --report <json>") }

    struct Score: Codable { let errors: Int; let referenceWords: Int; let wer: Double?; let error: String? }
    struct TermScore: Codable {
        let term: String; let baselineRawPreserved: Bool; let candidateRawPreserved: Bool
        let baselineFinalPreserved: Bool; let candidateFinalPreserved: Bool
    }
    struct ReportClip: Codable {
        let id: String; let group: String?; let category: String?; let reference: String
        let baseline: Score; let candidate: Score; let cleanedReference: String?
        let baselineCleanWER: Double?; let candidateCleanWER: Double?; let baselineCleanExact: Bool?; let candidateCleanExact: Bool?
        let criticalTerms: [TermScore]; let silence: Bool
        let baselineSeconds: Double; let baselineError: String?; let candidateRecognitionSeconds: Double; let candidateLoadSeconds: Double
        let candidateError: String?; let baselineRaw: String; let candidateRaw: String
        let baselineRules: String; let baselineFinal: String; let candidateRules: String; let candidateFinal: String
        let baselineUsedModel: Bool; let candidateUsedModel: Bool; let baselineRejection: String?; let candidateRejection: String?
        let baselineCleanupSeconds: Double; let candidateCleanupSeconds: Double
    }
    struct Aggregate: Codable { let wer: Double?; let errors: Int; let referenceWords: Int; let clipCount: Int; let errorCount: Int }
    struct Stratum: Codable { let dimension: String; let value: String; let baseline: Aggregate; let candidate: Aggregate }
    struct PairedCounts: Codable { let clips: Int; let wins: Int; let ties: Int; let losses: Int }
    struct Summary: Codable {
        let baseline: Aggregate; let candidate: Aggregate
        let baselineInferenceP50: Double?; let baselineInferenceP95: Double?; let candidateInferenceP50: Double?; let candidateInferenceP95: Double?
        let candidateLoadP50: Double?; let candidateLoadP95: Double?; let baselineCleanupP50: Double?; let baselineCleanupP95: Double?
        let candidateCleanupP50: Double?; let candidateCleanupP95: Double?; let baselineErrors: Int; let candidateErrors: Int
        let silenceCount: Int; let baselineSilenceHallucinations: Int; let candidateSilenceHallucinations: Int
        let strata: [Stratum]; let pairedRawSpeech: PairedCounts
    }
    struct Report: Codable {
        let schemaVersion: Int; let generatedAt: String; let baseline: String; let baselineRevision: String
        let candidateIdentities: [String]; let candidateAssetHashes: [String: [String: String]]; let candidateRuntimeSourceSHA256: String?
        let cleanupModelDirectory: String?; let cleanupModelFileSHA256: [String: String]; let cleanupModelComparison: Bool
        let manifestSHA256: String; let cleanup: String; let timingNote: String
        let clips: [ReportClip]; let summary: Summary
    }
}
