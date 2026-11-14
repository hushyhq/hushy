import Darwin
import Foundation
import Testing
@testable import MurmurCore

/// Page residency on real anonymous memory: what `mincore` reports, what a touch reads, and that a refresh
/// (resident pages only) never pages anything in.
@Suite("Page residency")
struct PageResidencyTests {
    /// An anonymous mapping that is unmapped when the test lets go of it.
    final class Mapping: @unchecked Sendable {
        let base: UnsafeMutableRawPointer
        let bytes: Int

        init(pages: Int) {
            bytes = pages * PageResidency.pageSize
            base = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)!
        }

        func write(pages range: Range<Int>) {
            for page in range { base.storeBytes(of: 1, toByteOffset: page * PageResidency.pageSize, as: UInt8.self) }
        }

        func regions() -> ModelMemoryRegions {
            ModelMemoryRegions(spans: [(UInt(bitPattern: base), bytes)], owner: self)
        }

        deinit { munmap(base, bytes) }
    }

    @Test("ranges are page-aligned, sorted and merged")
    func normalize() {
        let page = 16_384
        let ranges = ModelMemoryRegions.normalize(
            [(UInt(5 * page + 10), 100), (UInt(page), 2 * page), (UInt(2 * page), page), (0, 50), (UInt(9 * page), 0)],
            pageSize: page)
        #expect(ranges == [
            .init(address: UInt(page), bytes: 2 * page),
            .init(address: UInt(5 * page), bytes: page),
        ])
    }

    @Test("a fresh mapping holds nothing in RAM; written pages are resident")
    func sample() {
        let mapping = Mapping(pages: 64)
        #expect(PageResidency.sample(mapping.regions()).resident == 0)
        mapping.write(pages: 0..<16)
        let sample = PageResidency.sample(mapping.regions())
        #expect(sample.pages == 64)
        #expect(sample.resident == 16)
        #expect(abs(sample.fraction - 0.25) < 0.001)
    }

    @Test("a strided sample asks about every n-th page; small regions are sampled exactly")
    func strided() {
        let mapping = Mapping(pages: 64)
        mapping.write(pages: 0..<32)
        let sample = PageResidency.sample(mapping.regions(), stride: 2)
        #expect(sample.pages == 32)
        #expect(sample.resident == 16)
        #expect(PageResidency.sampleStride(mapping.regions()) == 1)
        let big = ModelMemoryRegions(spans: [(UInt(1 << 32), 212_709 * PageResidency.pageSize)], owner: nil)
        #expect(PageResidency.sampleStride(big) == 51)
    }

    @Test("a refresh reads only resident pages and pages nothing in")
    func refresh() {
        let mapping = Mapping(pages: 64)
        mapping.write(pages: 0..<10)
        let report = PageResidency.touch(mapping.regions(), threads: 2, chunkPages: 8, residentOnly: true)
        #expect(report.pages == 10)
        #expect(PageResidency.sample(mapping.regions()).resident == 10)
    }

    @Test("a full touch reads every page from several threads")
    func touchAll() {
        let mapping = Mapping(pages: 256)
        mapping.write(pages: 0..<256)
        let report = PageResidency.touch(mapping.regions(), threads: 4, chunkPages: 16)
        #expect(report.pages == 256)
        #expect(report.threads == 4)
        #expect(!report.stopped)
        #expect(PageResidency.sample(mapping.regions()).fraction == 1)
    }

    @Test("threads never exceed the chunks, and a stop request ends the touch")
    func threadsAndStop() {
        let mapping = Mapping(pages: 32)
        mapping.write(pages: 0..<32)
        #expect(PageResidency.touch(mapping.regions(), threads: 16, chunkPages: 16).threads == 2)
        let stopped = PageResidency.touch(mapping.regions(), threads: 2, chunkPages: 1, shouldStop: { true })
        #expect(stopped.stopped)
        #expect(stopped.pages == 0)
    }

    @Test("an empty region set is fully resident and touches nothing")
    func empty() {
        let regions = ModelMemoryRegions(spans: [], owner: nil)
        #expect(PageResidency.sample(regions).fraction == 1)
        #expect(PageResidency.touch(regions, threads: 4).pages == 0)
    }
}
