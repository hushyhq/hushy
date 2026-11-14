import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// `murmur-eval head-to-head play` — plays the founder's own recorded WAVs (`head-to-head
/// record`) to a chosen output device in real time, one case at a time, and saves whatever the
/// founder's app (Wispr Flow, or Hushy through the same flow) pastes into the capture window
/// (`HeadToHeadCaptureServer`) as a `filled.md` document `head-to-head build` already reads.
///
/// This is the piece that removes speaking-variance bias from gate 12: the same WAV goes into
/// both apps instead of the founder saying each paragraph twice. See
/// `docs/guide/HEAD-TO-HEAD-VIRTUAL-MIC.md` for the founder-facing setup (installing BlackHole,
/// selecting it as each app's mic, restoring settings afterwards).
enum HeadToHeadPlaybackRunner {
    struct Options {
        let casesDirectory: URL
        /// Ordered case ids to play, e.g. p-001..p-100 (from a template's slot plan, or every
        /// `*.wav` found in `casesDirectory` sorted by name if `--cases` isn't given).
        let caseIDs: [String]
        let deviceQuery: String
        let outURL: URL
        let product: String
        /// Seconds to wait after a clip finishes for the app to paste before treating the case
        /// as a silence timeout.
        let silenceTimeout: TimeInterval
    }

    static func run(_ args: Arguments) async throws {
        guard let dir = args.string("audio-dir") else { throw EvalError.missing("--audio-dir <dir with p-NNN.wav> is required") }
        guard let deviceQuery = args.string("device") else {
            let names = HeadToHeadDevices.listing(HeadToHeadDevices.outputDevices())
            throw EvalError.missing("--device <name> is required (substring match). Available output devices:\n\(names)")
        }
        guard let out = args.string("out") else { throw EvalError.missing("--out <filled.md> is required") }
        let product = args.string("product") ?? "Wispr Flow"
        let casesDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        let caseIDs = try resolveCaseIDs(args: args, directory: casesDirectory)
        guard !caseIDs.isEmpty else { throw EvalError.missing("No WAV files found in \(casesDirectory.path)") }

        let devices = HeadToHeadDevices.outputDevices()
        let match = HeadToHeadDevices.match(deviceQuery, in: devices)
        let device: HeadToHeadDevices.OutputDevice
        switch match {
        case .found(let found): device = found
        case .notFound: throw EvalError.missing("No output device matches \"\(deviceQuery)\". Available:\n\(HeadToHeadDevices.listing(devices))")
        case .ambiguous(let candidates): throw EvalError.missing("\"\(deviceQuery)\" matches more than one device:\n\(HeadToHeadDevices.listing(candidates))")
        }

        let options = Options(
            casesDirectory: casesDirectory, caseIDs: caseIDs, deviceQuery: deviceQuery,
            outURL: URL(fileURLWithPath: out), product: product,
            silenceTimeout: TimeInterval(args.int("silence-timeout") ?? 90))

        print("Playing \(caseIDs.count) case(s) to \"\(device.name)\".")
        print("Capture window: open the URL below, click into the text box, then focus \(product) and start it listening (its own hands-free toggle) before each clip plays.")

        let server = try await HeadToHeadCaptureServer.start()
        defer { server.stop() }
        print("  \(server.url.absoluteString)")
        _ = await MainActor.run { NSWorkspace.shared.open(server.url) }

        var session = HeadToHeadPlaybackSession(cases: options.caseIDs.map { id in
            .init(id: id, audioPath: options.casesDirectory.appendingPathComponent("\(id).wav").path)
        })

        let player = try DevicePlayer(deviceID: device.id)
        while let current = session.currentCase {
            let index = options.caseIDs.count - session.remaining
            server.setStatus(caseID: current.id, index: index, total: options.caseIDs.count, phase: "playing…")
            print("[\(index + 1)/\(options.caseIDs.count)] \(current.id) — playing")
            try await player.play(fileAt: URL(fileURLWithPath: current.audioPath))
            server.setStatus(caseID: current.id, index: index, total: options.caseIDs.count, phase: "listening — paste now")

            let event = await waitForEvent(server: server, timeout: options.silenceTimeout)
            let action = session.handle(event)
            switch action {
            case .saveAndAdvance(let id, let text):
                print("  captured \(text.split(separator: " ").count) word(s) for \(id)")
            case .advanceEmpty(let id):
                print("  no text captured for \(id) (silence timeout or skipped) — left empty, will show as missing in `build`")
            case .finished:
                break
            }
        }

        let markdown = session.renderFilledMarkdown(product: options.product)
        try FileManager.default.createDirectory(at: options.outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: options.outURL, atomically: true, encoding: .utf8)
        let filled = session.results.filter { !$0.text.isEmpty }.count
        print("Wrote \(filled)/\(session.results.count) filled slots to \(options.outURL.path)")
        if filled < session.results.count {
            let missing = session.results.filter { $0.text.isEmpty }.map(\.caseID)
            print("  empty: \(missing.joined(separator: ", "))")
        }
    }

    /// Races the capture server's event against the configured silence timeout, so a case where
    /// the founder's app never pastes anything doesn't hang the whole run.
    private static func waitForEvent(server: HeadToHeadCaptureServer, timeout: TimeInterval) async -> HeadToHeadPlaybackSession.Event {
        await withTaskGroup(of: HeadToHeadPlaybackSession.Event.self) { group in
            group.addTask { await server.nextEvent() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                server.forceTimeout()
                // The real event still comes back through the first task if it arrived just
                // before the timeout fired; this task's own return value is only used if the
                // first task's `nextEvent()` truly never resumes on its own, which `forceTimeout`
                // guarantees it will (see `HeadToHeadCaptureServer.forceTimeout`).
                return .silenceTimeout
            }
            let first = await group.next() ?? .silenceTimeout
            group.cancelAll()
            return first
        }
    }

    private static func resolveCaseIDs(args: Arguments, directory: URL) throws -> [String] {
        if let explicit = args.string("cases") {
            return explicit.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension.lowercased() == "wav" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

/// Plays one WAV file to a specific CoreAudio output device via `AVAudioEngine`, at real-time
/// speed (no time-stretching), matching how a live dictation would sound. Mirrors
/// `AudioCapture.setInputDevice` in `Sources/Murmur/Audio/AudioCapture.swift`, but on the output
/// unit instead of the input unit — that function is private to the `Murmur` target, so this is
/// a small output-side twin rather than a shared helper across targets.
private final class DevicePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(deviceID: AudioDeviceID) throws {
        engine.attach(player)
        // Connected lazily with each file's own format in `play(fileAt:)`, since the format
        // isn't known until the first WAV is opened; `nil` here just registers the node.
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        try Self.setOutputDevice(deviceID, on: engine)
    }

    private static func setOutputDevice(_ id: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw EvalError.missing("Could not set the output device (CoreAudio error \(status)). Is it still connected?")
        }
    }

    func play(fileAt url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        if !engine.isRunning {
            try engine.start()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            player.scheduleFile(file, at: nil) {
                continuation.resume()
            }
            player.play()
        }
    }
}
