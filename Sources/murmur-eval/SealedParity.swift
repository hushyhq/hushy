import Foundation
import HushyModelsMLX
import MurmurCore

/// `murmur-eval sealed-parity --plain <dir> --sealed <dir> --sealed-id <id>` with `HUSHY_SEALED_KEY_FILE` set:
/// loads the plain model with the stock loader and the sealed one with the in-memory loader, and compares every
/// weight byte for byte. Prints counts and timings, never weights or keys.
enum SealedParity {
    static func run(_ args: Arguments) async throws {
        guard let plain = args.string("plain"), let sealed = args.string("sealed"), let id = args.string("sealed-id"),
              let keys = EvalSealedKeys.fromEnvironment() else {
            throw EvalError.missing("sealed-parity needs --plain <dir> --sealed <dir> --sealed-id <id> and HUSHY_SEALED_KEY_FILE")
        }
        let report = try await SealedModelParity.compare(
            plainDirectory: URL(fileURLWithPath: plain, isDirectory: true),
            sealedDirectory: URL(fileURLWithPath: sealed, isDirectory: true), sealedModelID: id, keys: keys)
        print("sealed-parity tensors=\(report.tensors) bytes=\(report.bytes) mismatches=\(report.mismatches.count) "
            + "plainLoad=\(Int(report.plainLoadMilliseconds))ms sealedLoad=\(Int(report.sealedLoadMilliseconds))ms")
        for line in report.mismatches.prefix(20) { print("  \(line)") }
        // Predictive warm reads `memoryRegions()`: it must cover a sealed model's weights exactly as a plain one's.
        if let entry = args.string("local-model").flatMap(ModelRegistry.entry(id:)), let sealedEntry = ModelRegistry.entry(id: id) {
            func regions(_ entry: LocalModelEntry, _ folder: String) async throws -> (megabytes: Int, pages: Int) {
                let model = LocalCleanupBackend.model(for: entry, directory: URL(fileURLWithPath: folder, isDirectory: true), keys: keys)
                try await model.loadForMeasurement()
                guard let found = await model.memoryRegions() else { throw EvalError.missing("\(entry.id): no memory regions") }
                await model.unload()
                return (found.bytes >> 20, found.pages)
            }
            let plainRegions = try await regions(entry, plain)
            let sealedRegions = try await regions(sealedEntry, sealed)
            print("memory-regions plain=\(plainRegions.megabytes)MB/\(plainRegions.pages)pages sealed=\(sealedRegions.megabytes)MB/\(sealedRegions.pages)pages")
            guard plainRegions.megabytes == sealedRegions.megabytes else { throw EvalError.missing("sealed memory regions differ from plain") }
        }
        guard report.mismatches.isEmpty else { throw EvalError.missing("sealed and plain weights differ") }
    }
}
