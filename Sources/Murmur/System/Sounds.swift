import AVFoundation

/// Short, quiet cues synthesized once in memory. AVAudioPlayer owns each one-shot sound, so
/// dictation never starts or stops an output AVAudioEngine on the main actor.
@MainActor
final class Sounds {
    private let startTick = Sounds.makePlayer(from: 880, to: 1_320, duration: 0.045, volume: 0.09)
    private let stopTick = Sounds.makePlayer(from: 1_100, to: 740, duration: 0.05, volume: 0.07)
    private let errorTone = Sounds.makePlayer(from: 330, to: 220, duration: 0.16, volume: 0.1)
    var isEnabled = true

    func start() { play(startTick) }
    func stop() { play(stopTick) }
    func error() { play(errorTone) }

    private func play(_ player: AVAudioPlayer?) {
        guard isEnabled, let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func makePlayer(from startHz: Double, to endHz: Double,
                                   duration: Double, volume: Double) -> AVAudioPlayer? {
        let sampleRate = 44_100.0
        let frames = Int(sampleRate * duration)
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        var phase = 0.0
        for index in 0..<frames {
            let progress = Double(index) / Double(frames)
            phase += 2 * .pi * (startHz + (endHz - startHz) * progress) / sampleRate
            samples.append(Int16((sin(phase) * sin(.pi * progress) * volume * 32767).rounded()))
        }
        let bytes = UInt32(frames * MemoryLayout<Int16>.size)
        var wave = Data()
        wave.append(contentsOf: Array("RIFF".utf8))
        wave.appendLittleEndian(36 + bytes)
        wave.append(contentsOf: Array("WAVEfmt ".utf8))
        wave.appendLittleEndian(UInt32(16))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt16(1))
        wave.appendLittleEndian(UInt32(sampleRate))
        wave.appendLittleEndian(UInt32(sampleRate * 2))
        wave.appendLittleEndian(UInt16(2))
        wave.appendLittleEndian(UInt16(16))
        wave.append(contentsOf: Array("data".utf8))
        wave.appendLittleEndian(bytes)
        for sample in samples { wave.appendLittleEndian(sample) }
        guard let player = try? AVAudioPlayer(data: wave) else { return nil }
        player.prepareToPlay()
        return player
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
