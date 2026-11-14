import Foundation

/// Picks where to cut long recordings into chunks for progressive transcription, so cuts
/// land in pauses rather than in the middle of a word.
public enum ChunkSplitter {
    /// Returns the index at which to split `samples`: the start of the quietest 100 ms window
    /// within the final `searchSeconds`. Falls back to the end when the buffer is short.
    public static func splitIndex(_ samples: [Float], sampleRate: Double = 16_000, searchSeconds: Double = 3) -> Int {
        let window = Int(sampleRate * 0.1)
        let searchLength = Int(sampleRate * searchSeconds)
        guard samples.count > searchLength + window else { return samples.count }

        var bestIndex = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = samples.count - searchLength
        while start + window <= samples.count {
            var energy: Float = 0
            for index in start..<(start + window) { energy += samples[index] * samples[index] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = start + window / 2
            }
            start += window / 2
        }
        return bestIndex
    }
}
