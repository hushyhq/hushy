import CryptoKit
import Foundation

/// The capture journal's segment file (`hseg1`, meetings schema freeze section 3): a 16-byte header, then frames
/// appended every journal tick. A frame is `[u32 length][payload]`, little-endian. The payload is Int16 PCM followed
/// by a CRC32 when plaintext, or AES-GCM `nonce || ciphertext || tag` of that PCM when encrypted, so no plaintext
/// temp file is ever written (audit B21). A kill can tear only the last frame; `read` stops at the first frame that
/// does not check out and says where the good part ends.
public enum HsegFile {
    public static let magic: [UInt8] = Array("HSG1".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 16
    public static let sampleRate: UInt32 = 16_000
    static let encryptedFlag: UInt8 = 1
    static let nonceAndTag = 12 + 16
    /// A frame larger than this is a torn length, not audio (60 s of Int16 at 16 kHz is 1.9 MB).
    static let maxPayload = 4 * 1_024 * 1_024

    public enum Failure: Error, Equatable {
        case notHseg, wrongKey, unsupportedVersion
    }

    public static func header(encrypted: Bool) -> Data {
        var data = Data(magic)
        data.append(version)
        data.append(encrypted ? encryptedFlag : 0)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: le32(sampleRate))
        data.append(1)   // mono
        data.append(contentsOf: [0, 0, 0])
        return data
    }

    /// One frame for `samples`, ready to append.
    public static func frame(_ samples: [Float], key: SymmetricKey?) throws -> Data {
        let pcm = int16Bytes(samples)
        let payload: Data
        if let key {
            guard let combined = try AES.GCM.seal(pcm, using: key).combined else { throw EncryptionError.encryptionFailed }
            payload = combined
        } else {
            var plain = pcm
            plain.append(contentsOf: le32(CRC32.checksum(pcm)))
            payload = plain
        }
        var out = Data(le32(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    public struct Contents: Sendable, Equatable {
        public let samples: [Float]
        public let encrypted: Bool
        /// Bytes from the start of the file through the last good frame. Shorter than the file when it was torn.
        public let validLength: Int
        public let fileLength: Int
        public var isTorn: Bool { validLength < fileLength }
    }

    public static func read(_ url: URL, key: SymmetricKey?) throws -> Contents {
        try decode(Data(contentsOf: url), key: key)
    }

    public static func decode(_ data: Data, key: SymmetricKey?) throws -> Contents {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, Array(bytes[0..<4]) == magic else { throw Failure.notHseg }
        guard bytes[4] == version else { throw Failure.unsupportedVersion }
        let encrypted = bytes[5] & encryptedFlag != 0
        if encrypted, key == nil { throw Failure.wrongKey }
        var samples: [Float] = []
        var offset = headerSize
        while offset + 4 <= bytes.count {
            let length = Int(readLE32(bytes, at: offset))
            let start = offset + 4
            guard length > 0, length <= maxPayload, start + length <= bytes.count else { break }
            let payload = Data(bytes[start..<(start + length)])
            guard let pcm = open(payload, encrypted: encrypted, key: key) else {
                // A frame that fails its tag mid-file with good frames after it is a wrong key, not a tear.
                if encrypted, offset == headerSize { throw Failure.wrongKey }
                break
            }
            samples += floats(pcm)
            offset = start + length
        }
        return Contents(samples: samples, encrypted: encrypted, validLength: offset, fileLength: bytes.count)
    }

    private static func open(_ payload: Data, encrypted: Bool, key: SymmetricKey?) -> Data? {
        if encrypted {
            guard payload.count >= nonceAndTag, let key, let box = try? AES.GCM.SealedBox(combined: payload) else { return nil }
            return try? AES.GCM.open(box, using: key)
        }
        guard payload.count >= 4, (payload.count - 4) % 2 == 0 else { return nil }
        let pcm = payload.prefix(payload.count - 4)
        let stored = readLE32([UInt8](payload.suffix(4)), at: 0)
        return CRC32.checksum(pcm) == stored ? Data(pcm) : nil
    }

    static func int16Bytes(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
                out[index] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        return data
    }

    static func floats(_ pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / Float(Int16.max) }
        }
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// CRC-32 (IEEE 802.3), for plaintext journal frames.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// An append-only `.hseg.part` file: header at open, one frame per tick with `fsync`, `F_FULLFSYNC` at seal.
/// Not thread-safe; the journal writer owns it.
public final class HsegAppender {
    public let url: URL
    private let handle: FileHandle
    private let key: SymmetricKey?
    public private(set) var sampleCount = 0

    public init(creating url: URL, key: SymmetricKey?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: HsegFile.header(encrypted: key != nil),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.url = url
        self.key = key
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        _ = fsync(handle.fileDescriptor)
    }

    /// Appends one frame and syncs it to the disk, so a kill after this returns keeps these samples.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try handle.write(contentsOf: HsegFile.frame(samples, key: key))
        _ = fsync(handle.fileDescriptor)
        sampleCount += samples.count
    }

    /// Flushes to the platter (`F_FULLFSYNC`) and closes.
    public func close() throws {
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        try handle.close()
    }
}
