import Foundation
import MurmurCore

/// One side of a note recording as `NoteRecorder` drives it: start, drain each journal tick, rebuild when capture
/// health says it died, stop. The app's sides are the microphone (`AudioCapture`) and the call's audio
/// (`SystemAudioCapture`); the meeting-journal harness substitutes synthetic sides to stall or zero on cue.
@MainActor
protocol NoteAudioSource: AnyObject {
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws
    /// Stops capture; what was not drained yet stays for one last `drain()`.
    func stop() async
    func drain() -> [Float]
    var isRunning: Bool { get }
    /// Tears the stream down and builds it again. True when it came back.
    func rebuild(reason: String) async -> Bool
}

/// The microphone side: `AudioCapture` with the person's picked input.
@MainActor
final class MicrophoneNoteSource: NoteAudioSource {
    let capture: AudioCapture

    init(capture: AudioCapture) { self.capture = capture }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws { try capture.start(onLevel: onLevel) }

    func stop() async { _ = capture.stop() }

    func drain() -> [Float] { capture.drain() }

    var isRunning: Bool { capture.isRunning }

    func rebuild(reason: String) async -> Bool { capture.rebuild(reason: reason) }
}

/// The call's audio: a Core Audio process tap (or its ScreenCaptureKit fallback).
@MainActor
final class CallNoteSource: NoteAudioSource {
    let capture: SystemAudioCapture

    init(capture: SystemAudioCapture) { self.capture = capture }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws { try await capture.start(onLevel: onLevel) }

    func stop() async { _ = await capture.stop() }

    func drain() -> [Float] { capture.drain() }

    var isRunning: Bool { capture.isRunning }

    func rebuild(reason: String) async -> Bool { await capture.rebuild() }
}
