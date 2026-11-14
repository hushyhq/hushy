import Foundation

/// Rejoins upload-sized safetensors parts before the stock MLX loader reads them.
/// The result is cached beside the downloaded shards; a local unsharded override passes through.
enum MLXShardMaterializer {
    private typealias Span = (url: URL, start: UInt64, size: Int)
    /// Two loads of the same directory used to both pass the `.materialized` check, then one
    /// deleted that directory while the other was still reading it.
    private static let materializeLock = NSLock()

    static func loadDirectory(_ directory: URL) throws -> URL {
        materializeLock.lock()
        defer { materializeLock.unlock() }
        let manifestURL = directory.appendingPathComponent("reshard-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return directory }
        let target = directory.appendingPathComponent(".materialized", isDirectory: true)
        let weights = target.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: weights.path) { return target }
        let temporary = directory.appendingPathComponent(".materializing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let manifest = try object(at: manifestURL)
        let split = manifest["split_tensors"] as? [String: [String: Any]] ?? [:]
        let metadata = manifest["metadata"] as? [String: String] ?? [:]
        let index = try object(at: directory.appendingPathComponent("model.safetensors.index.json"))
        guard let map = index["weight_map"] as? [String: String] else { throw Error.invalidIndex }
        let (specs, ranges) = try collect(directory: directory, map: map)
        try writeWeights(at: temporary.appendingPathComponent("model.safetensors"),
                         split: split, metadata: metadata, specs: specs, ranges: ranges)
        try copyMetadata(from: directory, to: temporary)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private static func collect(directory: URL, map: [String: String]) throws -> ([String: [String: Any]], [String: Span]) {
        var specs = [String: [String: Any]]()
        var ranges = [String: Span]()
        for file in Set(map.values).sorted() {
            let url = directory.appendingPathComponent(file)
            let (header, dataStart) = try readHeader(url)
            for (name, value) in header where name != "__metadata__" {
                guard let spec = value as? [String: Any], let offsets = spec["data_offsets"] as? [Int], offsets.count == 2 else {
                    throw Error.invalidIndex
                }
                specs[name] = spec
                ranges[name] = (url, UInt64(dataStart + offsets[0]), offsets[1] - offsets[0])
            }
        }
        return (specs, ranges)
    }

    private static func writeWeights(
        at output: URL, split: [String: [String: Any]], metadata: [String: String],
        specs: [String: [String: Any]], ranges: [String: Span]
    ) throws {
        let names = Set(specs.keys.filter { !$0.contains(".__part") }).union(split.keys).sorted()
        var header: [String: Any] = ["__metadata__": metadata]
        var offset = 0
        for name in names {
            let pieces = split[name]?["parts"] as? [String] ?? [name]
            guard let first = specs[pieces[0]], pieces.allSatisfy({ ranges[$0] != nil }) else { throw Error.invalidIndex }
            let size = pieces.reduce(0) { $0 + (ranges[$1]?.size ?? 0) }
            header[name] = ["dtype": first["dtype"] as Any,
                            "shape": split[name]?["shape"] ?? first["shape"] as Any,
                            "data_offsets": [offset, offset + size]]
            offset += size
        }
        let encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var length = UInt64(encoded.count).littleEndian
        try writer.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try writer.write(contentsOf: encoded)
        for name in names {
            for piece in split[name]?["parts"] as? [String] ?? [name] {
                guard let range = ranges[piece] else { throw Error.invalidIndex }
                try append(range, to: writer)
            }
        }
    }

    private static func copyMetadata(from directory: URL, to temporary: URL) throws {
        for file in ["config.json", "chat_template.jinja", "tokenizer.json", "tokenizer_config.json", "generation_config.json"] {
            let source = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent(file))
            }
        }
    }

    private static func append(_ range: Span, to writer: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: range.url)
        defer { try? reader.close() }
        try reader.seek(toOffset: range.start)
        var remaining = range.size
        while remaining > 0 {
            let data = try reader.read(upToCount: min(remaining, 8 * 1024 * 1024)) ?? Data()
            guard !data.isEmpty else { throw Error.invalidIndex }
            try writer.write(contentsOf: data)
            remaining -= data.count
        }
    }

    private static func readHeader(_ url: URL) throws -> ([String: Any], Int) {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let prefix = try reader.read(upToCount: 8) ?? Data()
        guard prefix.count == 8 else { throw Error.invalidIndex }
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        guard length < 10_000_000, let bytes = try reader.read(upToCount: Int(length)), bytes.count == Int(length),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Error.invalidIndex }
        return (object, 8 + Int(length))
    }

    private static func object(at url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Error.invalidIndex
        }
        return value
    }

    enum Error: Swift.Error { case invalidIndex }
}
