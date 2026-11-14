@preconcurrency import AVFoundation
import Foundation
import MurmurCore

/// Streams an audio or video file's audio track to 16 kHz mono `Float` samples using
/// `AVAssetReader`, one compressed buffer at a time, so decoding a multi-hour file costs
/// constant memory rather than loading the whole file (or its whole decoded PCM) at once.
///
/// `AVAssetReader` decompresses whatever the container holds (AAC, ALAC, PCM, the audio track of
/// an MP4/MOV) into `AVAudioPCMBuffer`s as they're requested; `StreamingResampler` (the same
/// converter live microphone capture uses) reduces each buffer to 16 kHz mono immediately, so at
/// no point does the decoder hold more than one buffer's worth of the source format in memory.
enum MediaDecoder {
    enum DecodeError: LocalizedError {
        case noAudioTrack
        case readerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "This file has no audio track."
            case .readerFailed(let reason): "Couldn't read the audio: \(reason)"
            }
        }
    }

    /// Duration of the file's audio, in seconds, or `nil` if it can't be determined up front
    /// (used only to size a progress indicator — decoding proceeds either way).
    static func duration(of url: URL) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isValid, !duration.isIndefinite else { return nil }
        return duration.seconds
    }

    /// Decodes `url`'s audio track to 16 kHz mono as an `AsyncThrowingStream` of chunks, each
    /// yielded as soon as it's converted (never the whole file at once). The reader itself runs
    /// synchronously inside the stream's continuation callback (on whatever executor the caller
    /// iterates from), so a `for try await` loop over this sequence never needs to cross an
    /// isolation boundary per chunk — the caller's own local mutable state (accumulation buffers,
    /// counters) stays untouched by any Sendable-closure restriction. Cancelling the consuming
    /// `Task` stops decoding at the next chunk boundary.
    static func stream(contentsOf url: URL) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try await Self.read(contentsOf: url) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func read(contentsOf url: URL, onChunk: (sending [Float]) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw DecodeError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        // Ask for PCM directly: AVAssetReader decompresses AAC/ALAC/etc. itself when the output
        // settings request linear PCM, so this one output handles every container format this
        // feature supports (m4a, mp3, wav, aiff, caf, mp4, mov, m4v) without format-specific code.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.readerFailed("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "unknown reader error")
        }

        var resampler: StreamingResampler?
        var resamplerFormat: AVAudioFormat?

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { continue }
            if resamplerFormat == nil || resamplerFormat! != buffer.format {
                resampler = StreamingResampler(from: buffer.format)
                resamplerFormat = buffer.format
            }
            guard let resampler else { continue }
            let chunk = resampler.convert(buffer)
            if !chunk.isEmpty { onChunk(chunk) }
        }

        if reader.status == .failed {
            throw DecodeError.readerFailed(reader.error?.localizedDescription ?? "decoding failed")
        }
    }

    /// Wraps a `CMSampleBuffer` of non-interleaved float PCM as an `AVAudioPCMBuffer`, the format
    /// `StreamingResampler` expects. Returns nil for a buffer with no audio data (e.g. metadata-
    /// only samples some containers emit), which the caller skips.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        guard let format = AVAudioFormat(streamDescription: streamDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let channelCount = Int(format.channelCount)
        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer) == noErr, let dataPointer
        else { return nil }

        // Non-interleaved PCM stores each channel's samples contiguously, back to back.
        dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size) { floatPointer in
            for channel in 0..<channelCount {
                let channelOffset = channel * bytesPerChannel / MemoryLayout<Float>.size
                guard channelOffset + Int(frameCount) <= totalLength / MemoryLayout<Float>.size else { continue }
                buffer.floatChannelData?[channel].update(from: floatPointer + channelOffset, count: Int(frameCount))
            }
        }
        return buffer
    }
}
