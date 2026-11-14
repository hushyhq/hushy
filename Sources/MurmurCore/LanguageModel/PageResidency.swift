import Darwin
import Foundation
import Synchronization

/// The byte ranges a loaded model lives in (its weights and cached prefixes). `owner` keeps the memory
/// mapped for as long as this object is alive, so a page touch can run outside the model's actor while the
/// model is unloaded underneath it. Ranges are page-aligned, sorted and merged.
public final class ModelMemoryRegions: @unchecked Sendable {
    public struct Range: Equatable, Sendable {
        public let address: UInt
        public let bytes: Int
    }

    public let ranges: [Range]
    public let bytes: Int
    private let owner: AnyObject?

    public init(spans: [(address: UInt, bytes: Int)], owner: AnyObject?, pageSize: Int = PageResidency.pageSize) {
        self.owner = owner
        self.ranges = Self.normalize(spans, pageSize: pageSize)
        self.bytes = ranges.reduce(0) { $0 + $1.bytes }
    }

    public var pages: Int { bytes / PageResidency.pageSize }

    static func normalize(_ spans: [(address: UInt, bytes: Int)], pageSize: Int) -> [Range] {
        let mask = UInt(pageSize - 1)
        let aligned = spans.filter { $0.bytes > 0 && $0.address != 0 }.map { span -> (UInt, UInt) in
            let start = span.address & ~mask
            let end = (span.address + UInt(span.bytes) + mask) & ~mask
            return (start, end)
        }.sorted { $0.0 < $1.0 }
        var merged = [(UInt, UInt)]()
        for (start, end) in aligned {
            if let last = merged.last, start <= last.1 {
                merged[merged.count - 1].1 = max(last.1, end)
            } else {
                merged.append((start, end))
            }
        }
        return merged.map { Range(address: $0.0, bytes: Int($0.1 - $0.0)) }
    }
}

/// Whether a model's pages are in RAM, and a way to bring them back fast.
///
/// Why (TRY-95 follow-up, 2026-10-28): MLX reads the weights into anonymous memory, so under pressure macOS
/// compresses them and later writes them to swap. The next GPU pass then faults them back in: about 0.4 s from
/// the compressor, 7–14 s from swap in the founder's logs. Reading one byte per page from several CPU threads
/// pulls them back in parallel, ahead of the dictation (`ModelWarmthKeeper`) or at key-down.
public enum PageResidency {
    public static let pageSize = Int(getpagesize())

    public struct Sample: Equatable, Sendable {
        public var pages = 0
        public var resident = 0
        public var referenced = 0
        public var milliseconds = 0.0

        public var fraction: Double { pages == 0 ? 1 : Double(resident) / Double(pages) }
    }

    public struct TouchReport: Equatable, Sendable {
        public var pages = 0
        public var threads = 0
        public var milliseconds = 0.0
        public var stopped = false
    }

    /// `mincore` over every range; nothing is faulted in. `stride` > 1 asks about every stride-th page only, one
    /// call each: the whole 4B (212,709 pages) costs about 73 ms exact and a few ms at stride 64.
    public static func sample(_ regions: ModelMemoryRegions, stride: Int = 1) -> Sample {
        let start = ContinuousClock.now
        var sample = Sample()
        if stride > 1 {
            var bits: CChar = 0
            for range in regions.ranges {
                var offset = 0
                while offset < range.bytes {
                    guard let page = UnsafeMutableRawPointer(bitPattern: range.address + UInt(offset)) else { break }
                    if mincore(page, pageSize, &bits) == 0 { count(Int32(bits), into: &sample) }
                    sample.pages += 1
                    offset += stride * pageSize
                }
            }
            sample.milliseconds = milliseconds(since: start)
            return sample
        }
        var vector = [CChar]()
        for range in regions.ranges {
            let count = range.bytes / pageSize
            if vector.count < count { vector = [CChar](repeating: 0, count: count) }
            guard let base = UnsafeMutableRawPointer(bitPattern: range.address) else { continue }
            let status = vector.withUnsafeMutableBufferPointer { mincore(base, range.bytes, $0.baseAddress) }
            sample.pages += count
            guard status == 0 else { continue }
            for index in 0..<count { Self.count(Int32(vector[index]), into: &sample) }
        }
        sample.milliseconds = milliseconds(since: start)
        return sample
    }

    /// About 4,000 sampled pages tell the share in RAM to within a fraction of a percent: every 51st page of the
    /// 4B, 2.2 ms instead of 73. Small regions are sampled exactly.
    public static func sampleStride(_ regions: ModelMemoryRegions) -> Int { max(1, min(64, regions.pages / 4_096)) }

    private static func count(_ bits: Int32, into sample: inout Sample) {
        if bits & MINCORE_INCORE != 0 { sample.resident += 1 }
        if bits & (MINCORE_REFERENCED | MINCORE_REFERENCED_OTHER) != 0 { sample.referenced += 1 }
    }

    /// Reads one byte of every page from `threads` threads (each takes the next chunk of `chunkPages`
    /// pages), at the caller's QoS. `shouldStop` is checked between chunks. Read-only: nothing is written.
    ///
    /// `residentOnly` reads only the pages `mincore` reports in RAM: it marks them used without paging
    /// anything in (a "refresh"), for when the Mac is busy and taking memory back would cost someone else.
    public static func touch(
        _ regions: ModelMemoryRegions, threads: Int, chunkPages: Int = 1_024, residentOnly: Bool = false,
        shouldStop: @Sendable () -> Bool = { false }
    ) -> TouchReport {
        let start = ContinuousClock.now
        let chunks = Self.chunks(regions, pages: max(1, chunkPages))
        let workers = max(1, min(threads, chunks.count))
        let next = Atomic<Int>(0)
        let touched = Atomic<Int>(0)
        let stopped = Atomic<Bool>(false)
        let sink = Atomic<UInt>(0)
        let step = pageSize
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var sum: UInt = 0
            var vector = [CChar](repeating: 0, count: residentOnly ? max(1, chunkPages) : 0)
            while true {
                if shouldStop() { stopped.store(true, ordering: .relaxed); break }
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < chunks.count else { break }
                let chunk = chunks[index]
                guard let base = UnsafeRawPointer(bitPattern: chunk.address) else { continue }
                let count = chunk.bytes / step
                if residentOnly {
                    let status = vector.withUnsafeMutableBufferPointer {
                        mincore(UnsafeMutableRawPointer(mutating: base), chunk.bytes, $0.baseAddress)
                    }
                    guard status == 0 else { continue }
                }
                var read = 0
                for page in 0..<count where !residentOnly || Int32(vector[page]) & MINCORE_INCORE != 0 {
                    sum &+= UInt(base.load(fromByteOffset: page * step, as: UInt8.self))
                    read += 1
                }
                touched.add(read, ordering: .relaxed)
            }
            sink.add(sum, ordering: .relaxed)
        }
        _ = sink.load(ordering: .relaxed)
        return TouchReport(
            pages: touched.load(ordering: .relaxed), threads: workers,
            milliseconds: milliseconds(since: start), stopped: stopped.load(ordering: .relaxed))
    }

    /// Marks every page not recently used (`MADV_DONTNEED` on macOS deactivates; contents are kept), so the
    /// pager takes these pages first. Measurement only (`murmur-eval residency-probe`).
    public static func deactivate(_ regions: ModelMemoryRegions) {
        for range in regions.ranges {
            guard let base = UnsafeMutableRawPointer(bitPattern: range.address) else { continue }
            _ = madvise(base, range.bytes, MADV_DONTNEED)
        }
    }

    static func chunks(_ regions: ModelMemoryRegions, pages: Int) -> [ModelMemoryRegions.Range] {
        let size = pages * pageSize
        var result = [ModelMemoryRegions.Range]()
        for range in regions.ranges {
            var offset = 0
            while offset < range.bytes {
                let bytes = min(size, range.bytes - offset)
                result.append(.init(address: range.address + UInt(offset), bytes: bytes))
                offset += bytes
            }
        }
        return result
    }

    public static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
