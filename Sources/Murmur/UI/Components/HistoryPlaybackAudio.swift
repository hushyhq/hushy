import CryptoKit
import Foundation
import MurmurCore

/// Builds what History plays: the saved recording lifted to the same loudness the recogniser
/// heard. Dictation normalises before recognition (`LoudnessNormalizer`), but the file kept for
/// History is the raw microphone signal, so a quiet speaker's take played back faint. The lift
/// is applied here, at playback, with the same normaliser, so the saved file stays the raw
/// recording and recordings made before this change benefit too. Nothing here is written back.
enum HistoryPlaybackAudio {
    /// Size of the canonical 16-bit mono PCM WAV header `wavData(for:)` writes.
    static let headerByteCount = 44
    private static let sampleRate: UInt32 = 16_000

    /// Reads the saved recording (plaintext or encrypted), lifts it and returns WAV bytes for
    /// `AVAudioPlayer(data:)`. Blocking and proportional to the clip length: call off the main
    /// thread. Throws if the file can't be read or is empty.
    static func prepare(path: String, key: SymmetricKey?) throws -> Data {
        let samples = try WAVWriter.read(URL(fileURLWithPath: path), key: key)
        guard !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return wavData(for: samples)
    }

    /// The samples lifted by `LoudnessNormalizer` (quiet speech up to target, loud audio and
    /// silence untouched, soft-limited so it can't clip) as 16-bit mono 16 kHz WAV bytes.
    static func wavData(for samples: [Float]) -> Data {
        let lifted = LoudnessNormalizer.normalize(samples)
        let dataBytes = UInt32(lifted.count * 2)
        var data = Data(capacity: headerByteCount + Int(dataBytes))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))            // PCM, mono
        append(sampleRate); append(sampleRate * 2)      // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))           // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        for sample in lifted {
            append(Int16((max(-1, min(1, sample)) * 32_767).rounded()))
        }
        return data
    }
}
