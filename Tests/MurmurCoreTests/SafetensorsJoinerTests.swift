import Foundation
import Testing
@testable import MurmurCore

@Suite("Safetensors joiner")
struct SafetensorsJoinerTests {
    private func shard(root: URL, name: String, tensors: [(String, [Int], [UInt8])]) throws {
        var header = [String: Any]()
        var data = [UInt8]()
        for (name, shape, bytes) in tensors {
            header[name] = ["dtype": "U8", "shape": shape, "data_offsets": [data.count, data.count + bytes.count]]
            data += bytes
        }
        header["__metadata__"] = ["format": "mlx"]
        let encoded = try JSONSerialization.data(withJSONObject: header)
        var file = Data()
        file.append(littleEndian: UInt64(encoded.count))
        file.append(encoded)
        file.append(contentsOf: data)
        try file.write(to: root.appendingPathComponent(name))
    }

    @Test("shards become one stream, split tensors are rejoined, and the header is aligned")
    func joins() throws {
        let fixture = try SealedFixture()
        let root = try fixture.folder("model")
        try shard(root: root, name: "model-00001-of-00002.safetensors", tensors: [("a.__part000", [2], [1, 2]), ("b", [1], [9])])
        try shard(root: root, name: "model-00002-of-00002.safetensors", tensors: [("a.__part001", [2], [3, 4]), ("c", [3], [5, 6, 7])])
        let index: [String: Any] = ["weight_map": [
            "a.__part000": "model-00001-of-00002.safetensors", "b": "model-00001-of-00002.safetensors",
            "a.__part001": "model-00002-of-00002.safetensors", "c": "model-00002-of-00002.safetensors",
        ]]
        let manifest: [String: Any] = ["metadata": ["format": "mlx"], "split_tensors": ["a": ["dtype": "U8", "shape": [4], "parts": ["a.__part000", "a.__part001"]]]]
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("model.safetensors.index.json"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("reshard-manifest.json"))

        let joiner = try SafetensorsJoiner(directory: root)
        var bytes = Data()
        try joiner.stream(piece: 3) { bytes.append($0) }
        #expect(Int64(bytes.count) == joiner.totalBytes)
        let headerLength = Int(bytes.littleEndian(at: 0, as: UInt64.self))
        #expect(headerLength % 8 == 0)
        let header = try #require(JSONSerialization.jsonObject(with: bytes[8..<(8 + headerLength)]) as? [String: Any])
        let a = try #require(header["a"] as? [String: Any])
        #expect(a["shape"] as? [Int] == [4])
        #expect(header["__metadata__"] as? [String: String] == ["format": "mlx"])
        #expect(header.keys.sorted() == ["__metadata__", "a", "b", "c"])
        #expect(Array(bytes.dropFirst(8 + headerLength)) == [1, 2, 3, 4, 9, 5, 6, 7])
    }

    @Test("a folder with no weights, or an index naming a missing tensor, is refused")
    func refuses() throws {
        let fixture = try SealedFixture()
        let empty = try fixture.folder("empty")
        #expect(throws: SafetensorsJoiner.JoinError.self) { _ = try SafetensorsJoiner(directory: empty) }
    }

    @Test("a single unsharded model.safetensors is joined as it is")
    func single() throws {
        let fixture = try SealedFixture()
        let root = try fixture.folder("single")
        try shard(root: root, name: "model.safetensors", tensors: [("x", [2], [8, 9]), ("y", [1], [7])])
        let joiner = try SafetensorsJoiner(directory: root)
        var bytes = Data()
        try joiner.stream { bytes.append($0) }
        let headerLength = Int(bytes.littleEndian(at: 0, as: UInt64.self))
        #expect(Array(bytes.dropFirst(8 + headerLength)) == [8, 9, 7])
    }
}
