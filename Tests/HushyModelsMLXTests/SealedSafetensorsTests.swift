import Foundation
import MLX
import MurmurCore
import Testing
@testable import HushyModelsMLX

/// A safetensors file built in memory, sealed into a temp folder, and read back into `MLXArray`s.
@Suite("Sealed safetensors → MLX arrays", .serialized)
struct SealedSafetensorsTests {
    private let modelID = "test-sealed-enc1"
    private let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) })

    private struct Tensor {
        let name: String
        let dtype: String
        let shape: [Int]
        let bytes: [UInt8]
    }

    private func safetensors(_ tensors: [Tensor], metadata: [String: String] = ["format": "mlx"], overrides: [String: Any] = [:]) throws -> Data {
        var header: [String: Any] = ["__metadata__": metadata]
        var data = Data()
        for tensor in tensors {
            header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape, "data_offsets": [data.count, data.count + tensor.bytes.count]]
            data.append(contentsOf: tensor.bytes)
        }
        for (name, value) in overrides { header[name] = value }
        var encoded = try JSONSerialization.data(withJSONObject: header)
        encoded.append(Data(repeating: 0x20, count: (8 - encoded.count % 8) % 8))
        var file = Data()
        withUnsafeBytes(of: UInt64(encoded.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(encoded)
        file.append(data)
        return file
    }

    private func seal(_ plain: Data, in directory: URL, chunkSize: Int = 1024 * 1024) throws -> SealedPlainStream {
        let maxFile = Int64(SealedFormat.headerSize) + 4 * Int64(chunkSize + SealedFormat.nonceSize + SealedFormat.tagSize)
        let layout = try SealedLayout(totalPlain: Int64(plain.count), chunkSize: chunkSize, maxFileBytes: maxFile)
        let writer = try SealedWeightsWriter(key: key, modelID: modelID, layout: layout, directory: directory)
        try writer.append(plain)
        _ = try writer.finish()
        return try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: key, parallelism: 2)
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Building an `MLXArray` starts MLX's Metal device, which needs `mlx.metallib` beside the running executable; the test
    /// runner has none. The array path is covered on real models by `murmur-eval sealed-parity` (every weight byte against
    /// the stock loader, 4B and 2B), and these two run where a metallib is colocated: `HUSHY_MLX_ARRAY_TESTS=1`.
    private static let arraysAvailable = ProcessInfo.processInfo.environment["HUSHY_MLX_ARRAY_TESTS"] != nil

    @Test("every dtype the models use arrives with its shape and exact bytes, including a tensor bigger than the shared buffer",
          .enabled(if: SealedSafetensorsTests.arraysAvailable))
    func loadsTensors() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        func pattern(_ count: Int, seed: UInt8) -> [UInt8] {
            [UInt8](unsafeUninitializedCapacity: count) { buffer, filled in
                for index in 0..<count { buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed)) }
                filled = count
            }
        }
        let tensors = [
            Tensor(name: "a.f32", dtype: "F32", shape: [2, 3], bytes: pattern(24, seed: 1)),
            Tensor(name: "b.bf16", dtype: "BF16", shape: [4], bytes: pattern(8, seed: 2)),
            Tensor(name: "c.u32", dtype: "U32", shape: [3, 2], bytes: pattern(24, seed: 3)),
            Tensor(name: "d.i32", dtype: "I32", shape: [2], bytes: pattern(8, seed: 4)),
            Tensor(name: "e.f16", dtype: "F16", shape: [5], bytes: pattern(10, seed: 5)),
            Tensor(name: "f.u8", dtype: "U8", shape: [7], bytes: pattern(7, seed: 6)),
            Tensor(name: "g.empty", dtype: "F32", shape: [0], bytes: []),
            // Larger than the 64 MB shared buffer: takes its own buffer, and spans many chunks.
            Tensor(name: "h.big", dtype: "U8", shape: [65 * 1024 * 1024], bytes: pattern(65 * 1024 * 1024, seed: 7)),
        ]
        let stream = try seal(try safetensors(tensors), in: directory)
        let (weights, metadata) = try SealedSafetensors.load(from: stream)
        #expect(metadata == ["format": "mlx"])
        #expect(weights.count == tensors.count)
        let dtypes: [String: DType] = ["F32": .float32, "BF16": .bfloat16, "U32": .uint32, "I32": .int32, "F16": .float16, "U8": .uint8]
        for tensor in tensors where !tensor.bytes.isEmpty {
            let array = try #require(weights[tensor.name], "\(tensor.name)")
            #expect(array.shape == tensor.shape, "\(tensor.name)")
            #expect(array.dtype == dtypes[tensor.dtype], "\(tensor.name)")
            #expect(array.asData().data == Data(tensor.bytes), "\(tensor.name)")
        }
        #expect(weights["g.empty"]?.shape == [0])
        #expect(stream.remaining == 0)
    }

    @Test("the header of a sealed stream gives each tensor's type, shape and place, an empty tensor first, without building arrays")
    func readsTheHeader() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tensors = [
            Tensor(name: "a.f32", dtype: "F32", shape: [2, 3], bytes: Array(repeating: 1, count: 24)),
            Tensor(name: "b.bf16", dtype: "BF16", shape: [4], bytes: Array(repeating: 2, count: 8)),
            Tensor(name: "c.u32", dtype: "U32", shape: [3, 2], bytes: Array(repeating: 3, count: 24)),
            Tensor(name: "d.empty", dtype: "F32", shape: [0], bytes: []),
            Tensor(name: "e.f16", dtype: "F16", shape: [5], bytes: Array(repeating: 5, count: 10)),
            Tensor(name: "f.u8", dtype: "U8", shape: [7], bytes: Array(repeating: 6, count: 7)),
            Tensor(name: "g.big", dtype: "U8", shape: [3 * 1024 * 1024 + 5], bytes: Array(repeating: 7, count: 3 * 1024 * 1024 + 5)),
        ]
        let stream = try seal(try safetensors(tensors), in: directory)
        let (entries, metadata) = try SealedSafetensors.readHeader(from: stream)
        #expect(metadata == ["format": "mlx"])
        #expect(entries.count == tensors.count)
        var cursor = 0
        for entry in entries {
            let tensor = try #require(tensors.first { $0.name == entry.name })
            #expect(entry.shape == tensor.shape, "\(entry.name)")
            #expect(entry.range.count == tensor.bytes.count, "\(entry.name)")
            #expect(entry.range.lowerBound == cursor, "tiles the data with no gap: \(entry.name)")
            cursor = entry.range.upperBound
        }
        #expect(Int64(cursor) == stream.remaining)
        let types: [String: DType] = ["a.f32": .float32, "b.bf16": .bfloat16, "c.u32": .uint32, "e.f16": .float16, "f.u8": .uint8]
        for entry in entries { if let expected = types[entry.name] { #expect(entry.dtype == expected, "\(entry.name)") } }
    }

    @Test("a file whose tensors leave a gap, run past the data, or use an unknown type is refused")
    func malformed() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let one = Tensor(name: "a", dtype: "U8", shape: [4], bytes: [1, 2, 3, 4])
        // A gap: the second tensor starts after a hole.
        var gap = try safetensors([one], overrides: ["b": ["dtype": "U8", "shape": [2], "data_offsets": [6, 8]]])
        gap.append(contentsOf: [0, 0, 0, 0])
        #expect(throws: SealedSafetensors.Failure.self) { _ = try SealedSafetensors.readHeader(from: try seal(gap, in: try temporary())) }
        // Bytes after the last tensor.
        var trailing = try safetensors([one])
        trailing.append(contentsOf: [9, 9])
        #expect(throws: SealedSafetensors.Failure.self) { _ = try SealedSafetensors.readHeader(from: try seal(trailing, in: try temporary())) }
        // Shape does not match the byte count.
        let wrongShape = try safetensors([Tensor(name: "a", dtype: "F32", shape: [3], bytes: [1, 2, 3, 4])])
        #expect(throws: SealedSafetensors.Failure.self) { _ = try SealedSafetensors.readHeader(from: try seal(wrongShape, in: try temporary())) }
        // A type MLX cannot read here.
        let complex = try safetensors([Tensor(name: "a", dtype: "C64", shape: [1], bytes: Array(repeating: 0, count: 8))])
        #expect(throws: SealedSafetensors.Failure.unsupportedDType("C64")) { _ = try SealedSafetensors.readHeader(from: try seal(complex, in: try temporary())) }
        // Not a safetensors file at all.
        #expect(throws: SealedSafetensors.Failure.self) { _ = try SealedSafetensors.readHeader(from: try seal(Data(repeating: 0xFF, count: 64), in: try temporary())) }
    }

    @Test("loading touches no disk: nothing new beside the sealed files or in the temp folder holds the weights",
          .enabled(if: SealedSafetensorsTests.arraysAvailable))
    func writesNothing() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = Array("HUSHY-MLX-PLAINTEXT-MARKER".utf8)
        let bytes = (0..<20_000).map { marker[$0 % marker.count] }
        let stream = try seal(try safetensors([Tensor(name: "w", dtype: "U8", shape: [bytes.count], bytes: bytes)]), in: directory)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        _ = try SealedSafetensors.load(from: stream)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == before)
        let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        for name in tempAfter.subtracting(tempBefore) {
            let data = (try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent(name))) ?? Data()
            #expect(data.range(of: Data(marker)) == nil, "\(name)")
        }
        for name in before {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(data.range(of: Data(marker)) == nil, "\(name)")
        }
    }

    @Test("a wrong key stops the load before any tensor is built")
    func wrongKey() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try seal(try safetensors([Tensor(name: "a", dtype: "U8", shape: [4], bytes: [1, 2, 3, 4])]), in: directory)
        let stream = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: Data(repeating: 1, count: 32))
        #expect(throws: SealedWeightsError.authenticationFailed(chunk: 0)) { _ = try SealedSafetensors.readHeader(from: stream) }
    }
}
