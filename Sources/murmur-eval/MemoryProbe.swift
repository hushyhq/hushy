import Darwin
import Foundation
import HushyModelsMLX
import MurmurCore

/// One fresh-process sample of the app's local MLX model and whole-transcript cleanup path.
/// Input is invented; the JSON report contains timings and byte counts, never answer text.
enum MemoryProbe {
    struct Call: Codable {
        let words: Int
        let wallMilliseconds: Double
        let firstTokenMilliseconds: Double?
        let peakFootprintBytes: UInt64
        let modelAnswered: Bool
    }

    struct Report: Codable {
        let model: String
        let machineMemoryBytes: UInt64
        let baselineBytes: UInt64
        let loadMilliseconds: Double
        /// Highest `phys_footprint` seen (every 5 ms) while the model loaded: the load's peak memory.
        let loadPeakBytes: UInt64
        let afterLoadBytes: UInt64
        let afterPrefixBytes: UInt64
        let firstAfterLoad: Call
        let warm: Call
        let sixtySeconds: Call
        let twoHundredWords: Call
        let afterUnloadBytes: UInt64
        let afterUnloadSettledBytes: UInt64
        let allocatorAfterUnloadBytes: Int
    }

    static func run(_ args: Arguments) async throws {
        guard let folder = args.string("mlx-model"), let path = args.string("report") else {
            throw EvalError.missing("memory-probe needs --local-model <id> --mlx-model <dir> --report <json>")
        }
        let entry = try args.localModelEntry()
        let model = LocalCleanupBackend.model(
            for: entry, directory: URL(fileURLWithPath: folder, isDirectory: true), keys: EvalSealedKeys.fromEnvironment())
        let baseline = try footprint()
        let loadSampler = Task.detached(priority: .utility) { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled {
                if let now = try? footprint() { peak = max(peak, now) }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return peak
        }
        let started = ContinuousClock.now
        try await model.loadForMeasurement()
        let loadMs = milliseconds(since: started)
        loadSampler.cancel()
        let loadPeak = max(try footprint(), await loadSampler.value)
        let afterLoad = try footprint()

        // Whole transcript, one MLX call, with the same cleaner and pipeline as intent-app.
        let cleaner = SmartCleaner(model: model, repairsSpans: false, wholeTranscript: { true })
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .polished))
        let first = try await call(words: 24, model: model, pipeline: pipeline, settings: settings)
        let instructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true)
        await model.prefixCache(instructions: instructions)
        let afterPrefix = try footprint()
        let warm = try await call(words: 24, model: model, pipeline: pipeline, settings: settings)
        let sixty = try await call(words: 150, model: model, pipeline: pipeline, settings: settings)
        let long = try await call(words: 200, model: model, pipeline: pipeline, settings: settings)
        await model.unload()
        let afterUnload = try footprint()
        try await Task.sleep(for: .seconds(1))
        let settled = try footprint()
        let report = Report(
            model: entry.id, machineMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            baselineBytes: baseline, loadMilliseconds: loadMs, loadPeakBytes: loadPeak, afterLoadBytes: afterLoad,
            afterPrefixBytes: afterPrefix, firstAfterLoad: first, warm: warm,
            sixtySeconds: sixty, twoHundredWords: long, afterUnloadBytes: afterUnload,
            afterUnloadSettledBytes: settled,
            allocatorAfterUnloadBytes: MLXLanguageModel.allocatorMemoryBytes.active)
        let data = try JSONEncoder().encode(report)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("memory-probe model=\(entry.id) load=\(Int(loadMs))ms loadPeak=\(loadPeak) baseline=\(baseline) afterLoad=\(afterLoad) afterPrefix=\(afterPrefix) peak60=\(sixty.peakFootprintBytes) peak200=\(long.peakFootprintBytes) afterUnload=\(settled) report=\(path)")
    }

    private static func call(
        words: Int, model: MLXLanguageModel, pipeline: DictationPipeline, settings: PipelineSettings
    ) async throws -> Call {
        let text = draft(words: words)
        let before = model.stats.successes
        let started = ContinuousClock.now
        let sampler = Task.detached(priority: .utility) { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled {
                if let now = try? footprint() { peak = max(peak, now) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return peak
        }
        let result = await pipeline.clean(text, settings: settings, strategy: .model)
        let wall = milliseconds(since: started)
        sampler.cancel()
        let peak = max(try footprint(), await sampler.value)
        let answered = model.stats.successes > before
        guard answered else { throw EvalError.missing("MLX did not answer \(words)-word cleanup: \(result.rejection ?? "unknown")") }
        return Call(words: words, wallMilliseconds: wall,
                    firstTokenMilliseconds: model.lastCallTimings?.timeToFirstTokenMilliseconds,
                    peakFootprintBytes: peak, modelAnswered: answered)
    }

    static func draft(words: Int) -> String {
        let sentence = "Well I think the project note should explain the launch plan and the budget, actually move the budget to Friday because the team needs another day to check the figures."
        let tokens = sentence.split(separator: " ")
        return (0..<words).map { String(tokens[$0 % tokens.count]) }.joined(separator: " ")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw EvalError.missing("task_vm_info failed: \(result)") }
        return info.phys_footprint
    }
}
