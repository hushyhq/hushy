import Foundation
import MurmurCore
import Testing
@testable import HushyModelsMLX

/// How an instruction prefix build ends when its caller is cancelled (`MLXEngine.prefill`, the loop
/// `MLXEngine.prefix` runs its forward passes in). Each step stands for one chunk's forward pass.
@Suite("MLX prefix build under cancellation")
struct MLXPrefixCancelTests {
    private final class Record: @unchecked Sendable {
        var chunks: [Range<Int>] = []
        var rebuilds = 0
    }

    /// Prefills 1,000 tokens in 256-token chunks; the caller is cancelled during the first chunk's pass.
    private func cancelledDuringFirstChunk(_ onCancel: PrefixPolicy) async -> (Record, Bool) {
        let record = Record()
        let task = Task {
            do {
                try MLXEngine.prefill(count: 1_000, chunk: 256, policy: onCancel, rebuild: { record.rebuilds += 1 }) { range in
                    record.chunks.append(range)
                    if range.lowerBound == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        return (record, await task.value)
    }

    @Test("a summary's call (background) stops after the chunk in flight and leaves nothing to rebuild the prefix")
    func backgroundStops() async {
        let onCancel = PrefixPolicy(LanguageModelOptions(sampling: .greedy).background)
        #expect(onCancel == .background)
        let (record, threw) = await cancelledDuringFirstChunk(onCancel)
        #expect(threw)
        #expect(record.chunks == [0..<256], "no forward pass after the cancellation")
        #expect(record.rebuilds == 0, "nothing is left running on the model the dictation needs")
    }

    @Test("a dictation's call stops the same way and rebuilds its prefix off the caller's clock, for the next dictation")
    func dictationRebuilds() async {
        let onCancel = PrefixPolicy(.greedyTextTransform)
        #expect(onCancel == .dictation)
        let (record, threw) = await cancelledDuringFirstChunk(onCancel)
        #expect(threw)
        #expect(record.chunks == [0..<256])
        #expect(record.rebuilds == 1)
    }

    @Test("the policy of a call comes from its options alone: background is a bystander, every other call is a dictation's")
    func policyFollowsOptions() {
        let samplings: [LanguageModelOptions.Sampling] = [.greedy, .systemDefault]
        for sampling in samplings {
            for textTransform in [false, true] {
                let options = LanguageModelOptions(sampling: sampling, textTransform: textTransform)
                #expect(PrefixPolicy(options) == .dictation, "\(sampling) textTransform=\(textTransform)")
                #expect(PrefixPolicy(options.background) == .background, "\(sampling) textTransform=\(textTransform) background")
            }
        }
    }

    @Test("a warm-up runs every chunk whatever happens to its caller")
    func warmUpFinishes() async {
        let (record, threw) = await cancelledDuringFirstChunk(.warmUp)
        #expect(!threw)
        #expect(record.chunks == [0..<256, 256..<512, 512..<768, 768..<1_000])
        #expect(record.rebuilds == 0)
    }
}

private extension LanguageModelOptions {
    var background: LanguageModelOptions {
        var copy = self
        copy.isBackground = true
        return copy
    }
}
