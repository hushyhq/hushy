import CryptoKit
import Darwin
import Foundation

/// A sealed model folder's part files, validated against each other. Opening one reads only the 56-byte headers.
public struct SealedWeightsReader: Sendable {
    public let layout: SealedLayout
    public let modelID: String
    let parts: [URL]
    let modelTag: [UInt8]

    public init(directory: URL, modelID: String) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let found = names.compactMap { name in SealedFormat.parsePartName(name).map { (name, $0) } }
        guard let count = found.first?.1.count else { throw SealedWeightsError.notSealed }
        guard found.allSatisfy({ $0.1.count == count }) else { throw SealedWeightsError.badHeader("mixed part counts") }
        var urls: [URL] = []
        for index in 1...count {
            guard let name = found.first(where: { $0.1.index == index })?.0 else { throw SealedWeightsError.missingPart(index) }
            urls.append(directory.appendingPathComponent(name))
        }
        let tag = SealedFormat.modelTag(for: modelID)
        var layout: SealedLayout?
        for (offset, url) in urls.enumerated() {
            let header = try Self.readHeader(url)
            guard header.prefix(4).elementsEqual(SealedFormat.magic), header[4] == SealedFormat.version else {
                throw SealedWeightsError.badHeader("magic or version")
            }
            // Counts and sizes come from a file anyone can edit: out-of-range values are a bad header, never a trap.
            guard let first = Int(exactly: header.littleEndian(at: 20, as: UInt64.self)),
                  let total = Int64(exactly: header.littleEndian(at: 32, as: UInt64.self)) else {
                throw SealedWeightsError.badHeader("part \(offset + 1) sizes")
            }
            let chunkSize = Int(header.littleEndian(at: 8, as: UInt32.self))
            let index = Int(header.littleEndian(at: 12, as: UInt32.self))
            let partCount = Int(header.littleEndian(at: 16, as: UInt32.self))
            let chunks = Int(header.littleEndian(at: 28, as: UInt32.self))
            guard index == offset + 1, partCount == count, header.subdata(in: 40..<56).elementsEqual(tag) else {
                throw SealedWeightsError.badHeader("part \(offset + 1) belongs elsewhere")
            }
            if layout == nil {
                // Part 1 holds `chunksPerPart` chunks, unless it is the only part.
                layout = try SealedLayout(totalPlain: total, chunkSize: chunkSize, chunksPerPart: chunks)
            }
            guard let layout, layout.totalPlain == total, layout.chunkSize == chunkSize,
                  layout.partCount == count, !first.addingReportingOverflow(chunks).overflow,
                  layout.chunks(inPart: offset) == first..<(first + chunks) else {
                throw SealedWeightsError.badHeader("part \(offset + 1) disagrees with part 1")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == layout.fileBytes(ofPart: offset) else { throw SealedWeightsError.truncated(chunk: first) }
        }
        guard let layout else { throw SealedWeightsError.notSealed }
        self.layout = layout
        self.modelID = modelID
        self.parts = urls
        self.modelTag = tag
    }

    private static func readHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: SealedFormat.headerSize), header.count == SealedFormat.headerSize else {
            throw SealedWeightsError.badHeader("short header")
        }
        return header
    }

    /// Opens the stream. `parallelism` chunks are decrypted at a time (each holds a chunk of ciphertext and one of
    /// plaintext), and the next batch decrypts while the current one is read, so the working set is about
    /// `3 × parallelism × chunkSize`.
    public func plainStream(key: Data, parallelism: Int = 4) throws -> SealedPlainStream {
        guard key.count == SealedFormat.keySize else { throw SealedWeightsError.badKey }
        return try SealedPlainStream(reader: self, key: SymmetricKey(data: key), parallelism: max(1, parallelism))
    }

    /// Opens chunk 0 with `key`: whether these files were sealed with it. Cheap (one chunk).
    public func verifyKey(_ key: Data) throws {
        let stream = try plainStream(key: key, parallelism: 1)
        try stream.prime()
    }

    func openDescriptors() throws -> [Int32] {
        var descriptors: [Int32] = []
        for url in parts {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                descriptors.forEach { close($0) }
                throw SealedWeightsError.badHeader("cannot open \(url.lastPathComponent)")
            }
            descriptors.append(fd)
        }
        return descriptors
    }
}

/// Plaintext, in order, decrypted chunk by chunk in memory. Nothing is written anywhere.
public final class SealedPlainStream: @unchecked Sendable {
    private let reader: SealedWeightsReader
    private let key: SymmetricKey
    private let parallelism: Int
    private let descriptors: [Int32]
    private var nextToDecrypt = 0
    private var inFlight: Batch?
    private var ready: [Data] = []
    private var current = Data()
    private var offset = 0
    public private(set) var remaining: Int64

    init(reader: SealedWeightsReader, key: SymmetricKey, parallelism: Int) throws {
        self.reader = reader
        self.key = key
        self.parallelism = parallelism
        descriptors = try reader.openDescriptors()
        remaining = reader.layout.totalPlain
    }

    deinit {
        if case .success(var chunks)? = inFlight?.take() {
            for index in chunks.indices { wipe(&chunks[index]) }
        }
        descriptors.forEach { close($0) }
        wipe(&current)
        for index in ready.indices { wipe(&ready[index]) }
    }

    /// Decrypts the first batch (so a wrong key fails now).
    func prime() throws {
        if ready.isEmpty, nextToDecrypt == 0 { try takeBatch(prefetch: false) }
    }

    /// Fills `buffer` completely from the stream, or throws.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        guard Int64(buffer.count) <= remaining else { throw SealedWeightsError.unexpectedEnd }
        var written = 0
        while written < buffer.count {
            if offset == current.count {
                wipe(&current)
                if ready.isEmpty { try takeBatch(prefetch: true) }
                current = ready.removeFirst()
                offset = 0
            }
            let take = min(current.count - offset, buffer.count - written)
            current.withUnsafeBytes { source in
                _ = memcpy(buffer.baseAddress!.advanced(by: written), source.baseAddress!.advanced(by: offset), take)
            }
            offset += take
            written += take
        }
        remaining -= Int64(buffer.count)
    }

    public func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try read(into: $0) }
        return data
    }

    private func takeBatch(prefetch: Bool) throws {
        guard let batch = inFlight ?? startBatch() else { throw SealedWeightsError.unexpectedEnd }
        inFlight = nil
        ready.append(contentsOf: try batch.take().get())
        if prefetch { inFlight = startBatch() }
    }

    private func startBatch() -> Batch? {
        let range = nextToDecrypt..<min(reader.layout.chunkCount, nextToDecrypt + parallelism)
        guard !range.isEmpty else { return nil }
        nextToDecrypt = range.upperBound
        return Batch { try self.decryptChunks(range) }
    }

    private func decryptChunks(_ range: Range<Int>) throws -> [Data] {
        let slots = Slots(count: range.count)
        DispatchQueue.concurrentPerform(iterations: range.count) { slot in
            slots.set(slot, Result { try self.decrypt(chunk: range.lowerBound + slot) })
        }
        var firstError: Error?
        var decrypted: [Data] = []
        for result in slots.results {
            switch result {
            case .success(let data): decrypted.append(data)
            case .failure(let error): if firstError == nil { firstError = error }
            case nil: firstError = firstError ?? SealedWeightsError.unexpectedEnd
            }
        }
        if let firstError {
            for index in decrypted.indices { wipe(&decrypted[index]) }
            throw firstError
        }
        return decrypted
    }

    private func decrypt(chunk index: Int) throws -> Data {
        let layout = reader.layout
        let part = index / layout.chunksPerPart
        let first = layout.chunks(inPart: part).lowerBound
        let plainLength = layout.plainLength(ofChunk: index)
        let recordLength = plainLength + SealedFormat.nonceSize + SealedFormat.tagSize
        let position = Int64(SealedFormat.headerSize) + Int64(index - first) * Int64(layout.chunkSize + SealedFormat.nonceSize + SealedFormat.tagSize)
        var record = Data(count: recordLength)
        let got = record.withUnsafeMutableBytes { pread(descriptors[part], $0.baseAddress, recordLength, off_t(position)) }
        guard got == recordLength else { throw SealedWeightsError.truncated(chunk: index) }
        defer { wipe(&record) }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: record.prefix(SealedFormat.nonceSize)),
                ciphertext: record.dropFirst(SealedFormat.nonceSize).prefix(plainLength),
                tag: record.suffix(SealedFormat.tagSize))
            return try AES.GCM.open(
                box, using: key,
                authenticating: SealedFormat.aad(modelTag: reader.modelTag, chunkSize: layout.chunkSize, totalPlain: layout.totalPlain, chunk: index))
        } catch {
            throw SealedWeightsError.authenticationFailed(chunk: index)
        }
    }
}

/// Decrypted chunks, produced on another thread. `outcome` is written once before `done` is left and read only
/// after waiting on it, which is what makes the unchecked conformance sound.
private final class Batch: @unchecked Sendable {
    private let done = DispatchGroup()
    private var outcome: Result<[Data], Error> = .success([])

    init(_ work: @escaping @Sendable () throws -> [Data]) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            outcome = Result(catching: work)
            done.leave()
        }
    }

    /// Waits for the work and hands over its chunks; the batch keeps no reference to them.
    func take() -> Result<[Data], Error> {
        done.wait()
        defer { outcome = .success([]) }
        return outcome
    }
}

private final class Slots: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [Result<Data, Error>?]
    init(count: Int) { results = Array(repeating: nil, count: count) }
    func set(_ slot: Int, _ result: Result<Data, Error>) {
        lock.lock()
        results[slot] = result
        lock.unlock()
    }
}

private func wipe(_ data: inout Data) {
    guard !data.isEmpty else { return }
    data.resetBytes(in: 0..<data.count)
    data.removeAll(keepingCapacity: false)
}
