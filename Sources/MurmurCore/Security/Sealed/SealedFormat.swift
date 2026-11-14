import CryptoKit
import Foundation

/// The container a sealed model's weights travel and rest in (`docs/engineering/SEALED-MODELS.md`).
///
/// The plaintext is one byte stream (a safetensors file). It is cut into chunks of `chunkSize` bytes (the last
/// one shorter), and each chunk is sealed on its own with AES-256-GCM. The sealed chunks are laid out in
/// *part files* small enough to upload (`weights-00001-of-00013.hse`), each a header followed by whole chunk
/// records. Every chunk's additional authenticated data names the model, the chunk's place and the stream's
/// length, so a chunk moved, dropped, repeated or taken from another model fails its tag.
///
/// ```
/// part file   = header (56 bytes) | record | record | …
/// header      = "HSE1" | version u8 | 3 zero bytes | chunkSize u32 | partIndex u32 | partCount u32 |
///               firstChunk u64 | chunkCount u32 | totalPlain u64 | modelTag 16 bytes      (little endian)
/// record      = nonce (12) | ciphertext (chunk length) | tag (16)
/// AAD(i)      = "HSE1" | version u8 | modelTag (16) | chunkSize u32 | totalPlain u64 | i u64 (little endian)
/// modelTag    = first 16 bytes of SHA-256("hushy-sealed-model:" + model id)
/// ```
public enum SealedFormat {
    public static let magic = Array("HSE1".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 56
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let keySize = 32
    public static let fileExtension = "hse"
    /// The Keychain service a sealed model's key is filed under (the uninstall plan removes it).
    public static let keychainService = "app.hushy.model-keys"
    /// Plaintext bytes per chunk. Large enough for a fast sequential read, small enough that a loader holds a few.
    public static let defaultChunkSize = 16 * 1024 * 1024
    /// R2 takes objects up to 300 MiB through the dashboard; stay under it with room for the header.
    public static let defaultMaxFileBytes: Int64 = 300_000_000

    public static func partName(index: Int, count: Int) -> String {
        String(format: "weights-%05d-of-%05d.hse", index, count)
    }

    /// Whether `name` is a part file's name (and which part of how many).
    public static func parsePartName(_ name: String) -> (index: Int, count: Int)? {
        let pieces = name.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0] == "weights", pieces[2] == "of", pieces[3].hasSuffix(".hse"),
              let index = Int(pieces[1]), let count = Int(pieces[3].dropLast(4)), index >= 1, index <= count else { return nil }
        return (index, count)
    }

    /// The Worker secret that holds a model's key: `MODEL_KEY_` and the model id upper-cased, every other
    /// character an underscore (`hushy-cleanup-4b-r10d-6bit-enc1` becomes `MODEL_KEY_HUSHY_CLEANUP_4B_R10D_6BIT_ENC1`).
    /// `models-gate/src/keys.js` computes the same name.
    public static func workerSecretName(for modelID: String) -> String {
        "MODEL_KEY_" + String(modelID.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// The tag every chunk of a model's stream carries in its AAD and every part header carries.
    public static func modelTag(for modelID: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(("hushy-sealed-model:" + modelID).utf8)).prefix(16))
    }

    static func aad(modelTag: [UInt8], chunkSize: Int, totalPlain: Int64, chunk: Int) -> Data {
        var data = Data(magic)
        data.append(version)
        data.append(contentsOf: modelTag)
        data.append(littleEndian: UInt32(chunkSize))
        data.append(littleEndian: UInt64(totalPlain))
        data.append(littleEndian: UInt64(chunk))
        return data
    }

    /// Whether a model folder holds sealed weights (any part file), without opening them.
    public static func containsSealedWeights(in directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { parsePartName($0) != nil }
    }
}

/// How a plaintext stream of a given length is laid out: chunks, and chunks per part file.
public struct SealedLayout: Equatable, Sendable {
    /// A stream this long is not a model (1 PiB); it keeps arithmetic on a tampered header from overflowing.
    static let largestStream: Int64 = 1 << 50
    public let totalPlain: Int64
    public let chunkSize: Int
    public let chunkCount: Int
    public let chunksPerPart: Int
    public let partCount: Int

    public init(totalPlain: Int64, chunkSize: Int = SealedFormat.defaultChunkSize,
                maxFileBytes: Int64 = SealedFormat.defaultMaxFileBytes) throws {
        guard totalPlain > 0, totalPlain < SealedLayout.largestStream, chunkSize > 0 else { throw SealedWeightsError.badLayout }
        let record = Int64(chunkSize + SealedFormat.nonceSize + SealedFormat.tagSize)
        let perPart = Int((maxFileBytes - Int64(SealedFormat.headerSize)) / record)
        guard perPart >= 1 else { throw SealedWeightsError.badLayout }
        self.totalPlain = totalPlain
        self.chunkSize = chunkSize
        chunkCount = Int((totalPlain + Int64(chunkSize) - 1) / Int64(chunkSize))
        chunksPerPart = perPart
        partCount = (chunkCount + perPart - 1) / perPart
    }

    /// Plaintext bytes in chunk `index`.
    /// A layout read back from part headers: the stream length, the chunk size and how many chunks a part holds.
    public init(totalPlain: Int64, chunkSize: Int, chunksPerPart: Int) throws {
        guard totalPlain > 0, totalPlain < SealedLayout.largestStream, chunkSize > 0, chunksPerPart > 0 else { throw SealedWeightsError.badLayout }
        self.totalPlain = totalPlain
        self.chunkSize = chunkSize
        self.chunksPerPart = chunksPerPart
        chunkCount = Int((totalPlain + Int64(chunkSize) - 1) / Int64(chunkSize))
        partCount = (chunkCount + chunksPerPart - 1) / chunksPerPart
    }

    public func plainLength(ofChunk index: Int) -> Int {
        index == chunkCount - 1 ? Int(totalPlain - Int64(index) * Int64(chunkSize)) : chunkSize
    }

    public func chunks(inPart part: Int) -> Range<Int> {
        let first = part * chunksPerPart
        return first..<min(chunkCount, first + chunksPerPart)
    }

    /// Size on disk of part `part` (0-based), header included.
    public func fileBytes(ofPart part: Int) -> Int64 {
        chunks(inPart: part).reduce(Int64(SealedFormat.headerSize)) {
            $0 + Int64(plainLength(ofChunk: $1) + SealedFormat.nonceSize + SealedFormat.tagSize)
        }
    }
}

public enum SealedWeightsError: Error, Equatable, LocalizedError {
    case badLayout
    case notSealed
    case missingPart(Int)
    case badHeader(String)
    case truncated(chunk: Int)
    /// A chunk's tag did not verify. Chunk 0 failing on files whose SHA-256 matched means the key is not the one
    /// these files were sealed with; any other chunk means the file was damaged or changed.
    case authenticationFailed(chunk: Int)
    case badKey
    case unexpectedEnd

    public var isKeyMismatchCandidate: Bool { self == .authenticationFailed(chunk: 0) }

    public var errorDescription: String? {
        switch self {
        case .badLayout: "The sealed weights layout is not valid."
        case .notSealed: "This folder holds no sealed weights."
        case .missingPart(let index): "Sealed weights part \(index) is missing."
        case .badHeader(let why): "A sealed weights file is not valid (\(why))."
        case .truncated(let chunk): "A sealed weights file ends inside chunk \(chunk)."
        case .authenticationFailed(let chunk):
            chunk == 0 ? "The model key does not open these weights." : "Sealed weights chunk \(chunk) failed its check."
        case .badKey: "The model key is not a 256-bit key."
        case .unexpectedEnd: "The sealed weights ended before the model was complete."
        }
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func littleEndian<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size)) }
        return T(littleEndian: value)
    }
}
