import Foundation
import MurmurCore
import Testing
@testable import HushyModelsMLX

/// How long a dictation can wait behind a meeting summary or extract on the shared model (meetings schema freeze
/// section 8, "Preemption latency"): the call checks for cancellation before every prompt chunk and every decoded
/// token, so the wait is bounded by the largest single forward pass the call makes. For a background call that is at
/// most `backgroundPromptChunk` (128) tokens; a dictation's own calls keep their 512-token chunks.
@Suite("MLX background prompt chunks")
struct MLXBackgroundChunkTests {
    private let settings = MLXEngine.Settings(directory: URL(fileURLWithPath: "/nonexistent"))

    /// Every forward pass a call makes before its first decoded token: the lead chunks, then the decoder's first pass.
    private func passes(count: Int, policy: PrefixPolicy) throws -> [Int] {
        let plan = MLXEngine.promptPlan(count: count, policy: policy, settings: settings)
        var sizes: [Int] = []
        try MLXEngine.prefill(count: plan.lead, chunk: plan.chunk, policy: policy, rebuild: {}) { sizes.append($0.count) }
        sizes.append(count - plan.lead)
        return sizes
    }

    @Test("an extract-sized background prompt never makes a forward pass over 128 tokens, and feeds every token once")
    func backgroundPassesAreSmall() throws {
        #expect(settings.backgroundPromptChunk == 128)
        for count in [1, 100, 128, 129, 256, 1_000, 2_048, 5_900, 12_000] {
            let sizes = try passes(count: count, policy: .background)
            #expect(sizes.allSatisfy { $0 <= 128 }, "\(count) tokens: largest pass \(sizes.max() ?? 0)")
            #expect(sizes.reduce(0, +) == count, "\(count) tokens fed exactly once")
        }
    }

    @Test("a dictation's prompt keeps today's 512-token chunks and stays one pass up to 1,024 tokens")
    func dictationUnchanged() throws {
        #expect(try passes(count: 300, policy: .dictation) == [300])
        #expect(try passes(count: 1_024, policy: .dictation) == [1_024])
        let long = try passes(count: 2_000, policy: .dictation)
        #expect(long.max() == 512)
        #expect(long.reduce(0, +) == 2_000)
        #expect(MLXEngine.promptPlan(count: 900, policy: .dictation, settings: settings).lead == 0)
    }

    @Test("a background call cancelled during any chunk makes no further pass: the dictation waits for one chunk at most")
    func cancelledBackgroundStopsAfterOneChunk() async throws {
        let plan = MLXEngine.promptPlan(count: 5_900, policy: .background, settings: settings)
        let chunks = (plan.lead + plan.chunk - 1) / plan.chunk
        // A cancellation during the last lead chunk is caught by the decoder's own check before its first pass.
        for cancelAt in [0, 1, chunks / 2, chunks - 2] {
            final class Fed: @unchecked Sendable { var ranges: [Range<Int>] = [] }
            let fed = Fed()
            let threw = await Task {
                do {
                    try MLXEngine.prefill(count: plan.lead, chunk: plan.chunk, policy: .background, rebuild: {}) { range in
                        fed.ranges.append(range)
                        if fed.ranges.count == cancelAt + 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }.value
            #expect(threw, "cancelled at chunk \(cancelAt)")
            #expect(fed.ranges.count == cancelAt + 1, "no pass after the one in flight (cancelled at chunk \(cancelAt))")
            #expect(fed.ranges.allSatisfy { $0.count <= 128 })
        }
    }
}
