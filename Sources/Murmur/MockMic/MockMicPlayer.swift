#if DEBUG
import Foundation

/// Plays clips into BlackHole 2ch by running `tools/audio-loopback` as a child process. The player
/// itself only ever opens the device named exactly "BlackHole 2ch" and changes no system default.
struct MockMicPlayer {
    let executable: URL

    /// Plays each file in order and returns when the last one has finished.
    func play(_ files: [URL]) async throws {
        for file in files { try await run(file) }
    }

    /// The player gives up after 60 s of playback; refuse a longer clip with a clear message instead.
    static let maxClipSeconds = 58.0

    private func run(_ file: URL) async throws {
        let length = try MockMicAudio.duration(of: file)
        guard length <= Self.maxClipSeconds else {
            throw MockMicAudioError(description: "\(file.lastPathComponent) is \(Int(length)) s; clips must be \(Int(Self.maxClipSeconds)) s or shorter")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw MockMicAudioError(description: "player exited with status \(status) for \(file.lastPathComponent)") }
    }
}
#endif
