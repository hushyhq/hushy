import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Builds throw-away folders under the system temp directory, removed when the test ends.
final class SealedFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-test-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    static let otherKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })

    /// A recognisable plaintext: a marker text repeated, so a plaintext leak is easy to grep for.
    static let marker = Array("HUSHY-PLAINTEXT-MARKER-0123456789".utf8)

    static func plaintext(count: Int) -> Data {
        var data = Data(capacity: count)
        var counter: UInt32 = 0
        while data.count < count {
            data.append(contentsOf: marker)
            data.append(contentsOf: withUnsafeBytes(of: counter.littleEndian) { Array($0) })
            counter += 1
        }
        return data.prefix(count)
    }

    /// Seals `plain` into `directory` with small chunks and parts so a short stream spans several files.
    @discardableResult
    func seal(_ plain: Data, modelID: String = "test-model-enc1", key: Data = SealedFixture.key, into directory: URL,
              chunkSize: Int = 4096, chunksPerPart: Int = 3) throws -> [SealedPartSummary] {
        let maxFile = Int64(SealedFormat.headerSize + chunksPerPart * (chunkSize + SealedFormat.nonceSize + SealedFormat.tagSize))
        let layout = try SealedLayout(totalPlain: Int64(plain.count), chunkSize: chunkSize, maxFileBytes: maxFile)
        let writer = try SealedWeightsWriter(key: key, modelID: modelID, layout: layout, directory: directory)
        // Uneven pieces, to cross chunk boundaries at odd places.
        var offset = 0
        var step = 1_000
        while offset < plain.count {
            let end = min(plain.count, offset + step)
            try writer.append(plain[offset..<end])
            offset = end
            step = step == 1_000 ? 5_555 : 1_000
        }
        return try writer.finish()
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every file below `directory` (or only its direct children when `deep` is false) with its size and mtime.
    func tree(_ directory: URL, deep: Bool = true) -> [String: Int64] {
        var found: [String: Int64] = [:]
        let options: FileManager.DirectoryEnumerationOptions = deep ? [] : [.skipsSubdirectoryDescendants]
        let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: options)
        while let url = walker?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            found[url.path] = Int64(size) &+ Int64(((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0) * 1000)
        }
        return found
    }
}

@Suite("Sealed weights container")
struct SealedWeightsTests {
    private let modelID = "test-model-enc1"

    @Test("the chunk format round-trips: every byte comes back, across several part files")
    func roundTrip() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        let plain = SealedFixture.plaintext(count: 4096 * 10 + 1234)
        let parts = try fixture.seal(plain, into: directory)
        #expect(parts.count == 4) // 11 chunks, 3 per part
        #expect(parts.map(\.name) == (1...4).map { SealedFormat.partName(index: $0, count: 4) })
        for part in parts {
            #expect(try SealedFixture.sha256(directory.appendingPathComponent(part.name)) == part.sha256)
            let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(part.name).path)[.size] as? NSNumber
            #expect(size?.int64Value == part.bytes)
        }
        let reader = try SealedWeightsReader(directory: directory, modelID: modelID)
        #expect(reader.layout.totalPlain == Int64(plain.count))
        for parallelism in [1, 2, 4] {
            let stream = try reader.plainStream(key: SealedFixture.key, parallelism: parallelism)
            #expect(stream.remaining == Int64(plain.count))
            var rebuilt = Data()
            while stream.remaining > 0 { rebuilt.append(try stream.read(count: Int(min(stream.remaining, 777)))) }
            #expect(rebuilt == plain)
        }
    }

    @Test("a stream of exactly one chunk, and of one byte, round-trips")
    func edgeSizes() throws {
        for size in [1, 4096, 4097, 8192] {
            let fixture = try SealedFixture()
            let directory = try fixture.folder("m")
            let plain = SealedFixture.plaintext(count: size)
            try fixture.seal(plain, into: directory)
            let stream = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: SealedFixture.key)
            #expect(try stream.read(count: size) == plain)
            #expect(stream.remaining == 0)
            #expect(throws: SealedWeightsError.unexpectedEnd) { try stream.read(count: 1) }
        }
    }

    @Test("the ciphertext holds no trace of the plaintext")
    func ciphertextHidesPlaintext() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 50_000), into: directory)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(bytes.range(of: Data(SealedFixture.marker.prefix(16))) == nil, "\(name)")
        }
    }

    @Test("sealing the same plaintext with the same key gives the same files; another key gives other bytes")
    func deterministic() throws {
        let fixture = try SealedFixture()
        let plain = SealedFixture.plaintext(count: 30_000)
        let first = try fixture.seal(plain, into: try fixture.folder("a"))
        let second = try fixture.seal(plain, into: try fixture.folder("b"))
        let other = try fixture.seal(plain, key: SealedFixture.otherKey, into: try fixture.folder("c"))
        #expect(first == second)
        #expect(first.map(\.sha256) != other.map(\.sha256))
        // One changed chunk changes that chunk's nonce, so a key is never used twice with the same nonce on different data.
        var changed = plain
        changed[10] ^= 0xFF
        let third = try fixture.seal(changed, into: try fixture.folder("d"))
        let a = try Data(contentsOf: try fixture.folder("a").appendingPathComponent(first[0].name))
        let d = try Data(contentsOf: try fixture.folder("d").appendingPathComponent(third[0].name))
        let nonceRange = SealedFormat.headerSize..<(SealedFormat.headerSize + SealedFormat.nonceSize)
        #expect(a[nonceRange] != d[nonceRange])
    }

    @Test("a tampered chunk fails: one flipped bit in the ciphertext, the tag or the nonce")
    func tamperedChunk() throws {
        let plain = SealedFixture.plaintext(count: 4096 * 7)
        // Records are 4096 + 28 bytes; flip a bit in the second chunk (record 1) of part 1.
        let record = 4096 + SealedFormat.nonceSize + SealedFormat.tagSize
        let positions: [(String, Int)] = [
            ("ciphertext", SealedFormat.headerSize + record + SealedFormat.nonceSize + 100),
            ("tag", SealedFormat.headerSize + record + record - 3),
            ("nonce", SealedFormat.headerSize + record + 2),
        ]
        for (what, position) in positions {
            let fixture = try SealedFixture()
            let directory = try fixture.folder("model")
            try fixture.seal(plain, into: directory)
            let file = directory.appendingPathComponent(SealedFormat.partName(index: 1, count: 3))
            var bytes = try Data(contentsOf: file)
            bytes[position] ^= 0x01
            try bytes.write(to: file)
            let stream = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: SealedFixture.key, parallelism: 1)
            _ = try stream.read(count: 4096) // chunk 0 is intact
            #expect(throws: SealedWeightsError.authenticationFailed(chunk: 1), "\(what)") { try stream.read(count: 4096) }
        }
    }

    @Test("a tampered first chunk reads as a key mismatch candidate; a later one does not")
    func firstChunkIsTheKeyCheck() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 5), into: directory)
        let reader = try SealedWeightsReader(directory: directory, modelID: modelID)
        try reader.verifyKey(SealedFixture.key)
        #expect(throws: SealedWeightsError.authenticationFailed(chunk: 0)) { try reader.verifyKey(SealedFixture.otherKey) }
        #expect(SealedWeightsError.authenticationFailed(chunk: 0).isKeyMismatchCandidate)
        #expect(!SealedWeightsError.authenticationFailed(chunk: 3).isKeyMismatchCandidate)
    }

    @Test("a wrong key fails at the first chunk and releases no plaintext")
    func wrongKey() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 20_000), into: directory)
        let stream = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: SealedFixture.otherKey)
        #expect(throws: SealedWeightsError.authenticationFailed(chunk: 0)) { try stream.read(count: 10) }
        #expect(throws: SealedWeightsError.badKey) { _ = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: Data(count: 31)) }
    }

    @Test("chunks moved around inside a part fail: they are bound to their place")
    func reorderedChunks() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 6), into: directory)
        let file = directory.appendingPathComponent(SealedFormat.partName(index: 1, count: 2))
        var bytes = try Data(contentsOf: file)
        let record = 4096 + SealedFormat.nonceSize + SealedFormat.tagSize
        let first = bytes.subdata(in: SealedFormat.headerSize..<(SealedFormat.headerSize + record))
        let second = bytes.subdata(in: (SealedFormat.headerSize + record)..<(SealedFormat.headerSize + 2 * record))
        bytes.replaceSubrange(SealedFormat.headerSize..<(SealedFormat.headerSize + record), with: second)
        bytes.replaceSubrange((SealedFormat.headerSize + record)..<(SealedFormat.headerSize + 2 * record), with: first)
        try bytes.write(to: file)
        let stream = try SealedWeightsReader(directory: directory, modelID: modelID).plainStream(key: SealedFixture.key, parallelism: 1)
        #expect(throws: SealedWeightsError.authenticationFailed(chunk: 0)) { try stream.read(count: 10) }
    }

    @Test("files from another model, a missing part and a cut-short part are refused before anything is decrypted")
    func structuralDamage() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 7), into: directory)
        #expect(throws: SealedWeightsError.self) { _ = try SealedWeightsReader(directory: directory, modelID: "another-model") }

        let cut = try fixture.folder("cut")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 7), into: cut)
        let last = cut.appendingPathComponent(SealedFormat.partName(index: 3, count: 3))
        let data = try Data(contentsOf: last)
        try data.prefix(data.count - 5).write(to: last)
        #expect(throws: SealedWeightsError.self) { _ = try SealedWeightsReader(directory: cut, modelID: modelID) }

        let missing = try fixture.folder("missing")
        try fixture.seal(SealedFixture.plaintext(count: 4096 * 7), into: missing)
        try FileManager.default.removeItem(at: missing.appendingPathComponent(SealedFormat.partName(index: 2, count: 3)))
        #expect(throws: SealedWeightsError.missingPart(2)) { _ = try SealedWeightsReader(directory: missing, modelID: modelID) }

        let empty = try fixture.folder("empty")
        #expect(throws: SealedWeightsError.notSealed) { _ = try SealedWeightsReader(directory: empty, modelID: modelID) }
        #expect(!SealedFormat.containsSealedWeights(in: empty))
        #expect(SealedFormat.containsSealedWeights(in: directory))
    }

    @Test("a header edited to absurd numbers is a bad header, never a crash")
    func absurdHeaders() throws {
        // (offset, length) of each numeric header field: chunkSize, partIndex, partCount, firstChunk, chunkCount, totalPlain.
        let fields: [(Int, Int)] = [(8, 4), (12, 4), (16, 4), (20, 8), (28, 4), (32, 8)]
        for (offset, length) in fields {
            let fixture = try SealedFixture()
            let directory = try fixture.folder("model")
            try fixture.seal(SealedFixture.plaintext(count: 4096 * 5), into: directory)
            let file = directory.appendingPathComponent(SealedFormat.partName(index: 1, count: 2))
            var bytes = try Data(contentsOf: file)
            for position in offset..<(offset + length) { bytes[position] = 0xFF }
            try bytes.write(to: file)
            #expect(throws: SealedWeightsError.self, "field at \(offset)") { _ = try SealedWeightsReader(directory: directory, modelID: modelID) }
        }
    }

    @Test("part names and the Worker secret name")
    func names() {
        #expect(SealedFormat.partName(index: 3, count: 12) == "weights-00003-of-00012.hse")
        #expect(SealedFormat.parsePartName("weights-00003-of-00012.hse")?.index == 3)
        #expect(SealedFormat.parsePartName("weights-00003-of-00012.hse")?.count == 12)
        #expect(SealedFormat.parsePartName("model-00003-of-00012.safetensors") == nil)
        #expect(SealedFormat.parsePartName("weights-00013-of-00012.hse") == nil)
        // The same names `models-gate/src/keys.js` builds (its test pins these two).
        #expect(SealedFormat.workerSecretName(for: "hushy-cleanup-4b-r10d-6bit-enc1") == "MODEL_KEY_HUSHY_CLEANUP_4B_R10D_6BIT_ENC1")
        #expect(SealedFormat.workerSecretName(for: "a.b_c-d") == "MODEL_KEY_A_B_C_D")
    }

    @Test("reading sealed weights writes nothing: not beside the files, not in the temp folder, not in the home folder")
    func noPlaintextOnDisk() throws {
        let fixture = try SealedFixture()
        let directory = try fixture.folder("model")
        let home = try fixture.folder("home")
        let plain = SealedFixture.plaintext(count: 4096 * 9 + 17)
        try fixture.seal(plain, into: directory)
        let temporary = FileManager.default.temporaryDirectory
        let beforeModel = fixture.tree(directory)
        let beforeHome = fixture.tree(home)
        let beforeTemp = fixture.tree(temporary, deep: false).filter { !$0.key.contains("sealed-test-") }

        let reader = try SealedWeightsReader(directory: directory, modelID: modelID)
        let stream = try reader.plainStream(key: SealedFixture.key, parallelism: 3)
        var sum = 0
        while stream.remaining > 0 { sum += try stream.read(count: Int(min(stream.remaining, 4000))).count }
        #expect(sum == plain.count)

        #expect(fixture.tree(directory) == beforeModel)
        #expect(fixture.tree(home) == beforeHome)
        let afterTemp = fixture.tree(temporary, deep: false).filter { !$0.key.contains("sealed-test-") }
        // Other processes may touch the shared temp folder; nothing of ours (no new file with our marker) may appear.
        let newFiles = Set(afterTemp.keys).subtracting(beforeTemp.keys)
        for path in newFiles {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            #expect(bytes.range(of: Data(SealedFixture.marker.prefix(16))) == nil, "\(path)")
        }
    }
}
