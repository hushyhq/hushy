import Foundation

/// Reads a model folder's safetensors shards and writes them out as ONE safetensors byte stream, whole
/// tensors in a fixed order, tensors that were split across shards (`reshard-manifest.json`, written when a
/// tensor is larger than the upload limit) rejoined. This is the stream the sealer encrypts.
///
/// It is the same join the plain loader's `MLXShardMaterializer` does onto the disk, here streamed through a
/// closure so no plaintext file is ever written.
public struct SafetensorsJoiner {
    public enum JoinError: Error, Equatable { case invalidIndex(String) }

    private struct Piece { let url: URL; let start: UInt64; let size: Int }

    private let header: Data
    private let order: [[Piece]]
    public let totalBytes: Int64

    public init(directory: URL) throws {
        let files = try Self.weightFiles(in: directory)
        var specs: [String: [String: Any]] = [:]
        var pieces: [String: Piece] = [:]
        var firstMetadata: [String: String]?
        for url in files {
            let (header, dataStart) = try Self.readHeader(url)
            if firstMetadata == nil { firstMetadata = header["__metadata__"] as? [String: String] }
            for (name, value) in header where name != "__metadata__" {
                guard let spec = value as? [String: Any], let offsets = spec["data_offsets"] as? [Int], offsets.count == 2,
                      offsets[1] >= offsets[0] else { throw JoinError.invalidIndex("tensor \(name)") }
                specs[name] = spec
                pieces[name] = Piece(url: url, start: UInt64(dataStart + offsets[0]), size: offsets[1] - offsets[0])
            }
        }
        let manifestURL = directory.appendingPathComponent("reshard-manifest.json")
        var split: [String: [String: Any]] = [:]
        var metadata = firstMetadata ?? ["format": "mlx"]
        if let manifest = try? Self.object(at: manifestURL) {
            split = manifest["split_tensors"] as? [String: [String: Any]] ?? [:]
            metadata = manifest["metadata"] as? [String: String] ?? metadata
        }
        let names = Set(specs.keys.filter { !$0.contains(".__part") }).union(split.keys).sorted()
        var entries: [String: Any] = ["__metadata__": metadata]
        var offset = 0
        var order: [[Piece]] = []
        for name in names {
            let parts = split[name]?["parts"] as? [String] ?? [name]
            guard let first = specs[parts[0]], parts.allSatisfy({ pieces[$0] != nil }) else {
                throw JoinError.invalidIndex("tensor \(name)")
            }
            let size = parts.reduce(0) { $0 + (pieces[$1]?.size ?? 0) }
            entries[name] = ["dtype": first["dtype"] as Any, "shape": split[name]?["shape"] ?? first["shape"] as Any,
                             "data_offsets": [offset, offset + size]]
            offset += size
            order.append(parts.compactMap { pieces[$0] })
        }
        var encoded = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        encoded.append(Data(repeating: 0x20, count: (8 - encoded.count % 8) % 8))
        var lead = Data()
        lead.append(littleEndian: UInt64(encoded.count))
        self.header = lead + encoded
        self.order = order
        self.totalBytes = Int64(header.count + offset)
    }

    /// Calls `sink` with the stream in order, in pieces of at most `piece` bytes.
    public func stream(piece: Int = 8 * 1024 * 1024, into sink: (Data) throws -> Void) throws {
        try sink(header)
        for tensor in order {
            for part in tensor {
                let reader = try FileHandle(forReadingFrom: part.url)
                defer { try? reader.close() }
                try reader.seek(toOffset: part.start)
                var remaining = part.size
                while remaining > 0 {
                    guard let data = try reader.read(upToCount: min(remaining, piece)), !data.isEmpty else {
                        throw JoinError.invalidIndex("\(part.url.lastPathComponent) ends early")
                    }
                    try sink(data)
                    remaining -= data.count
                }
            }
        }
    }

    private static func weightFiles(in directory: URL) throws -> [URL] {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if let index = try? object(at: indexURL), let map = index["weight_map"] as? [String: String], !map.isEmpty {
            return Set(map.values).sorted().map { directory.appendingPathComponent($0) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let found = names.filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix(".") }.sorted()
        guard !found.isEmpty else { throw JoinError.invalidIndex("no safetensors files") }
        return found.map { directory.appendingPathComponent($0) }
    }

    private static func readHeader(_ url: URL) throws -> ([String: Any], Int) {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard let prefix = try reader.read(upToCount: 8), prefix.count == 8 else { throw JoinError.invalidIndex(url.lastPathComponent) }
        let length = prefix.littleEndian(at: 0, as: UInt64.self)
        guard length < 100_000_000, let bytes = try reader.read(upToCount: Int(length)), bytes.count == Int(length),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw JoinError.invalidIndex(url.lastPathComponent)
        }
        return (object, 8 + Int(length))
    }

    private static func object(at url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw JoinError.invalidIndex(url.lastPathComponent)
        }
        return value
    }
}
