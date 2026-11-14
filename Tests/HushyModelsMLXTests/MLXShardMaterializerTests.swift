import Foundation
import Testing
@testable import HushyModelsMLX

@Suite("MLX upload shards")
struct MLXShardMaterializerTests {
    @Test("split tensor rows are reconstructed under the original key")
    func reconstructs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-shard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try shard(root: root, name: "model-00001-of-00002.safetensors", tensors: [
            ("a.__part000", [2], [1, 2]), ("b", [1], [9]),
        ])
        try shard(root: root, name: "model-00002-of-00002.safetensors", tensors: [
            ("a.__part001", [2], [3, 4]),
        ])
        let index: [String: Any] = ["weight_map": [
            "a.__part000": "model-00001-of-00002.safetensors", "b": "model-00001-of-00002.safetensors",
            "a.__part001": "model-00002-of-00002.safetensors",
        ]]
        let manifest: [String: Any] = ["metadata": ["format": "mlx"], "split_tensors": ["a": [
            "shape": [4], "parts": ["a.__part000", "a.__part001"],
        ]]]
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("model.safetensors.index.json"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("reshard-manifest.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        // Start with no cache: every caller must get the same complete weights, even when
        // another load reaches the materialization check at the same time.
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let directory = try MLXShardMaterializer.loadDirectory(root)
                    return try Data(contentsOf: directory.appendingPathComponent("model.safetensors"))
                }
            }
            var results: [Data] = []
            for try await bytes in group { results.append(bytes) }
            return results
        }
        let bytes = try #require(results.first)
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == bytes })
        let headerLength = bytes.prefix(8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self).littleEndian) }
        let header = try #require(JSONSerialization.jsonObject(with: bytes[8..<8 + headerLength]) as? [String: [String: Any]])
        #expect(header["a"]?["shape"] as? [Int] == [4])
        #expect(header["b"]?["shape"] as? [Int] == [1])
        #expect(header["__metadata__"]?["format"] as? String == "mlx")
        #expect(Array(bytes.dropFirst(8 + headerLength)) == [1, 2, 3, 4, 9])
        #expect(try MLXShardMaterializer.loadDirectory(root) == root.appendingPathComponent(".materialized"))
    }

    private func shard(root: URL, name: String, tensors: [(String, [Int], [UInt8])]) throws {
        var header = [String: Any]()
        var data = [UInt8]()
        for (name, shape, bytes) in tensors {
            header[name] = ["dtype": "U8", "shape": shape, "data_offsets": [data.count, data.count + bytes.count]]
            data += bytes
        }
        let encoded = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(encoded.count).littleEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        try (prefix + encoded + Data(data)).write(to: root.appendingPathComponent(name))
    }
}
