import Darwin
import Foundation
import HushyModelsMLX
import MurmurCore

/// How long the first dictation after idle waits when macOS has compressed or swapped the model out, and what
/// each way of bringing it back costs. One fresh process per variant:
///
///   murmur-eval residency-probe --local-model <id> --mlx-model <dir> --report <json>
///       --restore gpu|touch|keydown|reload [--threads 4] [--max-gb 14] [--target 0.2] [--hold-seconds 10]
///
/// - gpu: today's key-down pass with nothing before it (the GPU faults the pages back in);
/// - touch: `PageResidency.touch` from `--threads` threads, then the same GPU pass;
/// - keydown: the shipped key-down path (`warmForDictation` with the page restore on);
/// - reload: unload, then load from disk and rebuild the prefix.
///
/// To push only this model out, its pages are first marked not recently used (`MADV_DONTNEED` keeps the
/// contents), then anonymous memory filled with noise is added 1 GB at a time until at most `--target` of the
/// pages are in RAM (or `--max-gb`). It still squeezes the Mac: run it alone through `scripts/mac-heavy.sh`.
/// Input is invented; the report holds timings, page counts and energy, never text.
enum ResidencyProbe {
    struct VM: Codable {
        var pageins: UInt64 = 0, swapins: UInt64 = 0, swapouts: UInt64 = 0, compressions: UInt64 = 0, decompressions: UInt64 = 0

        static func read() -> VM {
            var stats = vm_statistics64_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
            }
            return VM(pageins: stats.pageins, swapins: stats.swapins, swapouts: stats.swapouts,
                      compressions: stats.compressions, decompressions: stats.decompressions)
        }

        func since(_ before: VM) -> VM {
            VM(pageins: pageins &- before.pageins, swapins: swapins &- before.swapins, swapouts: swapouts &- before.swapouts,
               compressions: compressions &- before.compressions, decompressions: decompressions &- before.decompressions)
        }
    }

    /// This process's energy (nJ, Apple silicon) and CPU time (ns).
    struct Energy: Codable {
        var energyNanojoules: UInt64 = 0, cpuNanoseconds: UInt64 = 0, gpuNanoseconds: UInt64 = 0

        static func read() -> Energy {
            var info = task_power_info_v2()
            var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { return Energy() }
            // CPU and GPU times come in Mach ticks (24 MHz on Apple silicon), not nanoseconds.
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ns = { (ticks: UInt64) in ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom)) }
            return Energy(energyNanojoules: info.task_energy,
                          cpuNanoseconds: ns(info.cpu_energy.total_user + info.cpu_energy.total_system),
                          gpuNanoseconds: ns(info.gpu_energy.task_gpu_utilisation))
        }

        func since(_ before: Energy) -> Energy {
            Energy(energyNanojoules: energyNanojoules &- before.energyNanojoules,
                   cpuNanoseconds: cpuNanoseconds &- before.cpuNanoseconds, gpuNanoseconds: gpuNanoseconds &- before.gpuNanoseconds)
        }
    }

    struct Step: Codable {
        var milliseconds: Double
        var energy: Energy
        var vm: VM
    }

    struct Report: Codable {
        var model = "", variant = "", threads = 0, machineMemoryBytes: UInt64 = 0
        var weightMegabytes = 0, pages = 0
        var loadMilliseconds = 0.0, warmBeforeMilliseconds = 0.0, callBeforeMilliseconds = 0.0
        var sampleMilliseconds = 0.0
        var refreshResident: Step?
        var touchResidentOneThread: Step?
        var referencedAfterDeactivate = 0, referencedAfterGPUPass = 0, referencedAfterCPUTouch = 0
        var squeezeGigabytes = 0, residentAfterSqueeze = 0.0, residentAfterRelease = 0.0, vmDuringSqueeze = VM()
        var restore: Step?
        var residentAfterRestore = 0.0
        var warmAfter: Step?
        var warmAfterSecondMilliseconds = 0.0
        var callAfterMilliseconds = 0.0
        var firstDictationMilliseconds = 0.0
    }

    static func run(_ args: Arguments) async throws {
        guard let folder = args.string("mlx-model"), let path = args.string("report"), let variant = args.string("restore") else {
            throw EvalError.missing("residency-probe needs --local-model <id> --mlx-model <dir> --report <json> --restore gpu|touch|keydown|reload")
        }
        guard ["gpu", "touch", "keydown", "reload"].contains(variant) else { throw EvalError.missing("unknown --restore \(variant)") }
        let entry = try args.localModelEntry()
        let threads = args.int("threads") ?? WarmPolicy.restoreThreads
        let physical = ProcessInfo.processInfo.physicalMemory
        let maxGB = args.int("max-gb") ?? 14
        guard UInt64(maxGB + 8) << 30 <= physical else { throw EvalError.missing("--max-gb \(maxGB) leaves under 8 GB on this Mac") }
        let target = Double(args.string("target") ?? "0.2") ?? 0.2
        let hold = args.int("hold-seconds") ?? 10
        // Swapped rather than only compressed: keep adding memory until this many pages went to swap.
        let minSwapouts = UInt64(args.int("min-swapouts") ?? 0)

        var configuration = LocalCleanupBackend.configuration(
            for: entry, directory: URL(fileURLWithPath: folder, isDirectory: true), keys: EvalSealedKeys.fromEnvironment())
        configuration.restoresPagesOnKeyDown = variant == "keydown"
        let mlx = MLXLanguageModel(configuration: configuration)
        let instructions = SmartCleaner.cleanupInstructions(confidenceGuided: false)
        var report = Report(model: entry.id, variant: variant, threads: variant == "touch" ? threads : 0, machineMemoryBytes: physical)

        report.loadMilliseconds = try await timed { try await mlx.loadForMeasurement() }
        await mlx.prefixCache(instructions: instructions)
        _ = try await call(mlx, instructions)
        report.warmBeforeMilliseconds = await timed { await mlx.warmForDictation(instructions: instructions) }
        report.callBeforeMilliseconds = try await timed { _ = try await call(mlx, instructions) }

        guard var regions = await mlx.memoryRegions() else { throw EvalError.missing("model did not load") }
        report.weightMegabytes = regions.bytes >> 20
        report.pages = regions.pages
        report.sampleMilliseconds = PageResidency.sample(regions).milliseconds
        report.refreshResident = measure { _ = PageResidency.touch(regions, threads: 1, residentOnly: true) }
        report.touchResidentOneThread = measure { _ = PageResidency.touch(regions, threads: 1) }

        // Does a GPU pass mark the pages used, as far as the pager can see?
        PageResidency.deactivate(regions)
        report.referencedAfterDeactivate = PageResidency.sample(regions).referenced
        await mlx.warmForDictation(instructions: instructions)
        report.referencedAfterGPUPass = PageResidency.sample(regions).referenced
        _ = PageResidency.touch(regions, threads: 1)
        report.referencedAfterCPUTouch = PageResidency.sample(regions).referenced

        PageResidency.deactivate(regions)
        let squeezeStart = VM.read()
        report.squeezeGigabytes = squeeze(
            regions: regions, maxGB: maxGB, target: target, minSwapouts: minSwapouts, holdSeconds: hold
        ) { resident in
            report.residentAfterSqueeze = resident
        }
        report.vmDuringSqueeze = VM.read().since(squeezeStart)
        try await Task.sleep(for: .seconds(2))
        report.residentAfterRelease = PageResidency.sample(regions).fraction
        print("residency-probe squeezed=\(report.squeezeGigabytes)GB resident=\(report.residentAfterRelease)")

        let firstStart = ContinuousClock.now
        switch variant {
        case "touch":
            let touching = regions
            report.restore = measure { _ = PageResidency.touch(touching, threads: threads) }
        case "reload":
            // The regions retain the old arrays; let them go so the unload really frees them.
            regions = ModelMemoryRegions(spans: [], owner: nil)
            report.restore = try await measureAsync {
                await mlx.unload()
                try await mlx.loadForMeasurement()
                await mlx.prefixCache(instructions: instructions)
            }
        default:
            break
        }
        if variant != "reload" { report.residentAfterRestore = PageResidency.sample(regions).fraction }
        report.warmAfter = try await measureAsync { await mlx.warmForDictation(instructions: instructions) }
        report.warmAfterSecondMilliseconds = await timed { await mlx.warmForDictation(instructions: instructions) }
        report.callAfterMilliseconds = try await timed { _ = try await call(mlx, instructions) }
        report.firstDictationMilliseconds = PageResidency.milliseconds(since: firstStart)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        await mlx.unload()
        print("residency-probe restore=\(variant) threads=\(report.threads) restoreMs=\(Int(report.restore?.milliseconds ?? 0)) "
            + "warmAfterMs=\(Int(report.warmAfter?.milliseconds ?? 0)) callAfterMs=\(Int(report.callAfterMilliseconds)) "
            + "firstDictationMs=\(Int(report.firstDictationMilliseconds)) report=\(path)")
    }

    /// Adds noise-filled anonymous memory 1 GB at a time until at most `target` of the model's pages are in RAM
    /// and at least `minSwapouts` pages went to swap, keeps it in use for `holdSeconds`, then frees it. Returns
    /// the gigabytes used.
    private static func squeeze(
        regions: ModelMemoryRegions, maxGB: Int, target: Double, minSwapouts: UInt64, holdSeconds: Int,
        resident: (Double) -> Void
    ) -> Int {
        let start = VM.read()
        let gigabyte = 1 << 30
        var blocks = [UnsafeMutableRawPointer]()
        defer { for block in blocks { munmap(block, gigabyte) } }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var fraction = PageResidency.sample(regions).fraction
        while blocks.count < maxGB, fraction > target || VM.read().since(start).swapouts < minSwapouts {
            guard let raw = mmap(nil, gigabyte, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), raw != MAP_FAILED else { break }
            let words = raw.assumingMemoryBound(to: UInt64.self)
            for index in 0..<(gigabyte / 8) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                words[index] = state
            }
            blocks.append(raw)
            fraction = PageResidency.sample(regions).fraction
        }
        let deadline = ContinuousClock.now + .seconds(holdSeconds)
        var round: UInt8 = 1
        while ContinuousClock.now < deadline {
            for block in blocks {
                let bytes = block.assumingMemoryBound(to: UInt8.self)
                var offset = 0
                while offset < gigabyte { bytes[offset] = round; offset += PageResidency.pageSize }
            }
            round &+= 1
        }
        resident(PageResidency.sample(regions).fraction)
        return blocks.count
    }

    private static func call(_ mlx: MLXLanguageModel, _ instructions: String) async throws -> String {
        try await mlx.respond(
            instructions: instructions, prompt: MemoryProbe.draft(words: 24), schema: SmartCleaner.cleanedSchema, options: .greedy)
    }

    private static func timed(_ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        return PageResidency.milliseconds(since: start)
    }

    private static func measure(_ body: () -> Void) -> Step {
        let energy = Energy.read(), vm = VM.read(), start = ContinuousClock.now
        body()
        return Step(milliseconds: PageResidency.milliseconds(since: start), energy: Energy.read().since(energy), vm: VM.read().since(vm))
    }

    private static func measureAsync(_ body: () async throws -> Void) async rethrows -> Step {
        let energy = Energy.read(), vm = VM.read(), start = ContinuousClock.now
        try await body()
        return Step(milliseconds: PageResidency.milliseconds(since: start), energy: Energy.read().since(energy), vm: VM.read().since(vm))
    }
}
