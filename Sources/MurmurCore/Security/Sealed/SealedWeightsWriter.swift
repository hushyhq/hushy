import CryptoKit
import Foundation

/// One part file the writer produced, with what the registry and the Worker's allowlist pin.
public struct SealedPartSummary: Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
}

/// Seals a plaintext stream into part files (`SealedFormat`). Used by the build tool (`hushy-model-seal`),
/// never by the app.
///
/// Nonces are derived from the key, the chunk's place and the chunk's own SHA-256 (a synthetic IV), so sealing
/// the same plaintext with the same key gives the same files byte for byte (the registry can pin their SHA-256,
/// and a rebuild from the saved key reproduces the upload), while two different plaintexts never share a nonce
/// under one key.
public final class SealedWeightsWriter {
    public let layout: SealedLayout
    private let key: SymmetricKey
    private let modelTag: [UInt8]
    private let directory: URL
    private var pending = Data()
    private var received: Int64 = 0
    private var nextChunk = 0
    private var part: (handle: FileHandle, hasher: SHA256, bytes: Int64, index: Int)?
    private var summaries: [SealedPartSummary] = []

    public init(key: Data, modelID: String, layout: SealedLayout, directory: URL) throws {
        guard key.count == SealedFormat.keySize else { throw SealedWeightsError.badKey }
        self.key = SymmetricKey(data: key)
        self.modelTag = SealedFormat.modelTag(for: modelID)
        self.layout = layout
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pending.reserveCapacity(layout.chunkSize)
    }

    public func append(_ bytes: Data) throws {
        guard received + Int64(bytes.count) <= layout.totalPlain else { throw SealedWeightsError.badLayout }
        received += Int64(bytes.count)
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let want = layout.plainLength(ofChunk: nextChunk) - pending.count
            let take = min(want, bytes.endIndex - offset)
            pending.append(bytes[offset..<(offset + take)])
            offset += take
            if pending.count == layout.plainLength(ofChunk: nextChunk) { try sealPending() }
        }
    }

    public func finish() throws -> [SealedPartSummary] {
        guard received == layout.totalPlain, nextChunk == layout.chunkCount else { throw SealedWeightsError.unexpectedEnd }
        try closePart()
        return summaries
    }

    private func sealPending() throws {
        let index = nextChunk
        let partIndex = index / layout.chunksPerPart
        if part?.index != partIndex {
            try closePart()
            try openPart(partIndex)
        }
        let nonce = Self.nonce(key: key, chunk: index, plaintext: pending)
        let box = try AES.GCM.seal(
            pending, using: key, nonce: AES.GCM.Nonce(data: nonce),
            authenticating: SealedFormat.aad(modelTag: modelTag, chunkSize: layout.chunkSize, totalPlain: layout.totalPlain, chunk: index))
        var record = Data(capacity: pending.count + SealedFormat.nonceSize + SealedFormat.tagSize)
        record.append(contentsOf: nonce)
        record.append(box.ciphertext)
        record.append(box.tag)
        try write(record)
        pending.resetBytes(in: 0..<pending.count)
        pending.removeAll(keepingCapacity: true)
        nextChunk += 1
    }

    static func nonce(key: SymmetricKey, chunk: Int, plaintext: Data) -> Data {
        var input = Data("hse1-nonce".utf8)
        input.append(littleEndian: UInt64(chunk))
        input.append(contentsOf: SHA256.hash(data: plaintext))
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key).prefix(SealedFormat.nonceSize))
    }

    private func openPart(_ index: Int) throws {
        let name = SealedFormat.partName(index: index + 1, count: layout.partCount)
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw SealedWeightsError.badLayout }
        let handle = try FileHandle(forWritingTo: url)
        part = (handle, SHA256(), 0, index)
        let chunks = layout.chunks(inPart: index)
        var header = Data(SealedFormat.magic)
        header.append(SealedFormat.version)
        header.append(contentsOf: [0, 0, 0])
        header.append(littleEndian: UInt32(layout.chunkSize))
        header.append(littleEndian: UInt32(index + 1))
        header.append(littleEndian: UInt32(layout.partCount))
        header.append(littleEndian: UInt64(chunks.lowerBound))
        header.append(littleEndian: UInt32(chunks.count))
        header.append(littleEndian: UInt64(layout.totalPlain))
        header.append(contentsOf: modelTag)
        precondition(header.count == SealedFormat.headerSize)
        try write(header)
    }

    private func write(_ data: Data) throws {
        guard var current = part else { throw SealedWeightsError.badLayout }
        try current.handle.write(contentsOf: data)
        current.hasher.update(data: data)
        current.bytes += Int64(data.count)
        part = current
    }

    private func closePart() throws {
        guard let current = part else { return }
        try current.handle.close()
        let digest = current.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        summaries.append(SealedPartSummary(
            name: SealedFormat.partName(index: current.index + 1, count: layout.partCount), bytes: current.bytes, sha256: digest))
        part = nil
    }
}
