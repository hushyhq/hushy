import Darwin
import Foundation
import MurmurCore

/// `murmur-eval diarize-bakeoff` scores one diarizer on one public set and writes a JSON result
/// (per-file DER parts at two collars, speaker counts, timing, peak memory, hypothesis turns), so
/// `scripts/diarizer-bakeoff.sh` can run every backend in its own process and compare peak memory.
///
///   murmur-eval diarize-bakeoff --diarizer legacy|community1|nemotron-offline|nemotron-fast128|nemotron-fast32|nemotron-c128-w8a8
///     --dataset ami-sdm|ami-sdm-dev|voxconverse-test|notsofar-sc [--files N] [--data-dir DIR]
///     [--threshold F] [--tag NAME]
///
/// `--data-dir` defaults to `.build/public-data` under the current directory; audio, references and
/// FluidAudio's model downloads all live there. `--threshold` sets community-1's clustering cut or
/// Nemotron's per-frame speaker probability cut (FluidAudio's default 0.5).
enum DiarizeBakeoffRunner {
    static let collars = [0.0, 0.25]

    struct FileResult: Codable {
        let id: String
        let durationSeconds: Double
        let elapsedSeconds: Double
        let refSpeakers: Int
        let hypSpeakers: Int
        /// Keyed by collar, as "0.00" and "0.25".
        let der: [String: DERParts]
        let hypothesis: [Turn]
    }

    struct DERParts: Codable {
        let missed: Double
        let falseAlarm: Double
        let confusion: Double
        let reference: Double
        var der: Double { reference > 0 ? (missed + falseAlarm + confusion) / reference : 0 }
    }

    struct Turn: Codable {
        let speaker: String
        let start: Double
        let end: Double
    }

    struct RunResult: Codable {
        let backend: String
        let dataset: String
        let tag: String
        let threshold: Double?
        let modelLoadSeconds: Double
        let peakFootprintMB: Double
        let peakResidentMB: Double
        let files: [FileResult]
        let skipped: [String]
    }

    static func run(_ args: Arguments) async throws {
        guard let backend = args.string("diarizer").flatMap(BakeoffBackend.init(rawValue:)),
              let dataset = args.string("dataset").flatMap(BakeoffDataset.init(rawValue:))
        else {
            throw EvalError.missing("usage: murmur-eval diarize-bakeoff --diarizer \(BakeoffBackend.allCases.map(\.rawValue).joined(separator: "|")) --dataset \(BakeoffDataset.allCases.map(\.rawValue).joined(separator: "|")) [--files N] [--data-dir DIR] [--threshold F] [--tag NAME]")
        }
        let root = URL(fileURLWithPath: args.string("data-dir") ?? FileManager.default.currentDirectoryPath + "/.build/public-data", isDirectory: true)
        let threshold = args.string("threshold").flatMap(Double.init)
        let ids = Array(dataset.fileIds.prefix(args.int("files") ?? dataset.fileIds.count))
        let tag = args.string("tag") ?? backend.rawValue + (threshold.map { "-t\($0)" } ?? "")

        let loadStart = Date()
        let diarizer = try await backend.make(
            modelsBase: root.appendingPathComponent("fluidaudio-models", isDirectory: true), threshold: threshold)
        let modelLoadSeconds = Date().timeIntervalSince(loadStart)
        print("\(backend.rawValue): models ready in \(String(format: "%.1f", modelLoadSeconds))s")

        var files: [FileResult] = []
        var skipped: [String] = []
        var warmedUp = false
        for id in ids {
            let file: BakeoffFile
            do { file = try await dataset.load(id: id, root: root) } catch {
                print("  \(id): SKIPPED, \(error.localizedDescription)")
                skipped.append(id)
                continue
            }
            if !warmedUp {
                _ = try? await diarizer.diarize(Array(file.audio.prefix(16_000 * 30)))
                warmedUp = true
            }
            let start = Date()
            let hypothesis = try await diarizer.diarize(file.audio)
            let elapsed = Date().timeIntervalSince(start)
            let result = score(file: file, hypothesis: hypothesis, elapsed: elapsed)
            print(String(
                format: "  %@: %.0fs, DER %.1f%% (collar 0.25) / %.1f%% (collar 0), speakers %d/%d, %.0fx real time",
                id, file.durationSeconds, (result.der["0.25"]?.der ?? 0) * 100, (result.der["0.00"]?.der ?? 0) * 100,
                result.hypSpeakers, result.refSpeakers, file.durationSeconds / max(elapsed, 0.0001)))
            files.append(result)
        }

        let memory = peakMemory()
        let run = RunResult(
            backend: backend.rawValue, dataset: dataset.rawValue, tag: tag, threshold: threshold,
            modelLoadSeconds: modelLoadSeconds, peakFootprintMB: memory.footprint, peakResidentMB: memory.resident,
            files: files, skipped: skipped)
        let outDir = root.appendingPathComponent("diarizer-bakeoff/\(dataset.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(tag).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: outURL, options: .atomic)
        print(summary(run))
        print("wrote \(outURL.path)")
    }

    static func score(file: BakeoffFile, hypothesis: [DERSegment], elapsed: Double) -> FileResult {
        var parts: [String: DERParts] = [:]
        for collar in collars {
            let result = DiarizationErrorRate.compute(reference: file.reference, hypothesis: hypothesis, collar: collar)
            parts[String(format: "%.2f", collar)] = DERParts(
                missed: result.missedSpeechSeconds, falseAlarm: result.falseAlarmSeconds,
                confusion: result.confusionSeconds, reference: result.totalReferenceSpeechSeconds)
        }
        return FileResult(
            id: file.id, durationSeconds: file.durationSeconds, elapsedSeconds: elapsed,
            refSpeakers: Set(file.reference.map(\.speaker)).count, hypSpeakers: Set(hypothesis.map(\.speaker)).count,
            der: parts, hypothesis: hypothesis.map { Turn(speaker: $0.speaker, start: $0.start, end: $0.end) })
    }

    /// Pooled DER (total error time over total reference time, the NIST and pyannote convention).
    static func summary(_ run: RunResult) -> String {
        func pooled(_ collar: String) -> DERParts {
            run.files.compactMap { $0.der[collar] }.reduce(DERParts(missed: 0, falseAlarm: 0, confusion: 0, reference: 0)) {
                DERParts(missed: $0.missed + $1.missed, falseAlarm: $0.falseAlarm + $1.falseAlarm,
                         confusion: $0.confusion + $1.confusion, reference: $0.reference + $1.reference)
            }
        }
        func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
        let strict = pooled("0.00")
        let loose = pooled("0.25")
        let audio = run.files.map(\.durationSeconds).reduce(0, +)
        let compute = run.files.map(\.elapsedSeconds).reduce(0, +)
        let exact = run.files.count { $0.hypSpeakers == $0.refSpeakers }
        let countError = Double(run.files.map { abs($0.hypSpeakers - $0.refSpeakers) }.reduce(0, +)) / Double(max(run.files.count, 1))
        return """
            ### Diarizer bakeoff · \(run.tag) · \(run.dataset) · \(run.files.count) file(s)\(run.skipped.isEmpty ? "" : ", skipped \(run.skipped.joined(separator: ","))")
            | collar | DER | missed | false alarm | confusion |
            |---|---|---|---|---|
            | 0.25 s | \(pct(loose.der)) | \(pct(loose.missed / max(loose.reference, 1e-9))) | \(pct(loose.falseAlarm / max(loose.reference, 1e-9))) | \(pct(loose.confusion / max(loose.reference, 1e-9))) |
            | 0 s | \(pct(strict.der)) | \(pct(strict.missed / max(strict.reference, 1e-9))) | \(pct(strict.falseAlarm / max(strict.reference, 1e-9))) | \(pct(strict.confusion / max(strict.reference, 1e-9))) |
            - Speaker count exact: \(exact)/\(run.files.count); mean absolute count error \(String(format: "%.2f", countError))
            - Speed: \(String(format: "%.0f", audio / max(compute, 1e-9)))x real time over \(String(format: "%.0f", audio / 60)) min of audio; model load \(String(format: "%.1f", run.modelLoadSeconds)) s
            - Peak memory: footprint \(String(format: "%.0f", run.peakFootprintMB)) MB, resident \(String(format: "%.0f", run.peakResidentMB)) MB
            """
    }

    private static func peakMemory() -> (resident: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.resident_size_peak) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
