import Foundation
import MLX
import MurmurCore

/// Reads a safetensors file that arrives as a stream of decrypted bytes (`SealedPlainStream`) straight into
/// `MLXArray`s, one tensor at a time. Nothing is written to disk and no file-sized buffer is held: the working
/// set is the tensor being read (the biggest is the embedding, under 500 MB) plus the decryptor's few chunks.
///
/// Stock MLX reads weights from a file path with `pread`; it has no reader that takes a stream. The in-memory
/// reader (`loadArrays(data:)`) would need the whole file as one `Data`, and a pipe or a mounted image would put
/// the plaintext where other processes can reach it, so the file is parsed here instead. The format is small:
/// `u64 header length`, a JSON header (`dtype`, `shape`, `data_offsets` per tensor, and `__metadata__`), then the
/// tensor bytes, back to back.
enum SealedSafetensors {
    enum Failure: Error, Equatable, LocalizedError {
        case malformed(String)
        case unsupportedDType(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let why): "The sealed weights are not a valid safetensors file (\(why))."
            case .unsupportedDType(let name): "The sealed weights use a tensor type MLX cannot read here (\(name))."
            }
        }
    }

    struct Entry {
        let name: String
        let dtype: DType
        let shape: [Int]
        let range: Range<Int>
    }

    /// Tensors under this many bytes are read through one reusable buffer; bigger ones get their own, freed at once.
    private static let sharedBufferBytes = 64 * 1024 * 1024

    /// Reads the header from `stream` and checks that the tensors tile the data exactly. Touches no MLX array.
    static func readHeader(from stream: SealedPlainStream) throws -> (entries: [Entry], metadata: [String: String]) {
        let prefix = try stream.read(count: 8)
        let declared = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard declared > 0, declared <= 512 * 1024 * 1024, Int64(declared) <= stream.remaining else {
            throw Failure.malformed("header length")
        }
        let headerLength = Int(declared)
        let headerBytes = try stream.read(count: headerLength)
        let (entries, metadata) = try parse(header: headerBytes, dataBytes: stream.remaining)
        return (entries, metadata)
    }

    static func load(from stream: SealedPlainStream) throws -> (weights: [String: MLXArray], metadata: [String: String]) {
        let (entries, metadata) = try readHeader(from: stream)
        var weights = [String: MLXArray](minimumCapacity: entries.count)
        let shared = UnsafeMutableRawBufferPointer.allocate(byteCount: sharedBufferBytes, alignment: 16)
        defer { wipe(shared); shared.deallocate() }
        for entry in entries {
            let count = entry.range.count
            if count == 0 {
                weights[entry.name] = MLXArray.zeros(entry.shape, dtype: entry.dtype)
                continue
            }
            let own = count > sharedBufferBytes ? UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 16) : nil
            let buffer = own ?? UnsafeMutableRawBufferPointer(rebasing: shared[0..<count])
            defer {
                wipe(buffer)
                own?.deallocate()
            }
            try stream.read(into: buffer)
            // `MLXArray(Data, shape, dtype:)` copies the bytes into MLX's own storage.
            let view = Data(bytesNoCopy: buffer.baseAddress!, count: count, deallocator: .none)
            weights[entry.name] = MLXArray(view, entry.shape, dtype: entry.dtype)
        }
        guard stream.remaining == 0 else { throw Failure.malformed("bytes after the last tensor") }
        return (weights, metadata)
    }

    private static func parse(header: Data, dataBytes: Int64) throws -> ([Entry], [String: String]) {
        guard let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            throw Failure.malformed("header is not JSON")
        }
        var entries: [Entry] = []
        for (name, value) in object where name != "__metadata__" {
            guard let spec = value as? [String: Any], let dtypeName = spec["dtype"] as? String,
                  let shape = spec["shape"] as? [Int], let offsets = spec["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0] else { throw Failure.malformed("tensor \(name)") }
            guard let dtype = Self.dtypeFor(name: dtypeName) else { throw Failure.unsupportedDType(dtypeName) }
            let elements = shape.reduce(1, *)
            guard elements >= 0, elements * dtype.size == offsets[1] - offsets[0] else {
                throw Failure.malformed("tensor \(name) size")
            }
            entries.append(Entry(name: name, dtype: dtype, shape: shape, range: offsets[0]..<offsets[1]))
        }
        // The stream is read once, in order, so the tensors must tile the data exactly.
        // An empty tensor shares its start with the next one; it goes first.
        entries.sort { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        var cursor = 0
        for entry in entries {
            guard entry.range.lowerBound == cursor else { throw Failure.malformed("gap or overlap before \(entry.name)") }
            cursor = entry.range.upperBound
        }
        guard Int64(cursor) == dataBytes else { throw Failure.malformed("data length") }
        return (entries, object["__metadata__"] as? [String: String] ?? [:])
    }

    static func dtypeFor(name: String) -> DType? {
        switch name {
        case "BOOL": .bool
        case "U8": .uint8
        case "U16": .uint16
        case "U32": .uint32
        case "U64": .uint64
        case "I8": .int8
        case "I16": .int16
        case "I32": .int32
        case "I64": .int64
        case "F16": .float16
        case "BF16": .bfloat16
        case "F32": .float32
        default: nil
        }
    }

    private static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }
}
