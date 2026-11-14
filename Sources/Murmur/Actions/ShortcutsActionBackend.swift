import Foundation
import MurmurCore

/// Real Shortcuts backend: runs `/usr/bin/shortcuts run <name>` as a subprocess, per
/// docs/research/voice-actions.md §3 (no special entitlement needed to invoke the CLI itself;
/// the Shortcut's own contents may separately need Automation permission, granted to the
/// Shortcuts app/`shortcutsd`, not to Hushy). Never used directly by tests — see
/// `FakeShortcutsBackend` in MurmurCore.
struct RealShortcutsActionBackend: ShortcutsActionBackend {
    /// Hard timeout so a Shortcut that hangs (or one that itself prompts for input Hushy can't
    /// provide — voice-actions.md's MVP scope explicitly excludes those) can't leave the pill
    /// stuck in "processing" forever.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    /// Runs the Shortcut. A run that starts and then times out or exits with an error throws
    /// `.mayHaveRun`: the Shortcut's own steps may already have done something Hushy cannot see
    /// (`ShortcutRunOutcome`). Its output is never shown or logged, since it can hold anything.
    func run(name: String, input: String?) async throws -> String {
        var arguments = ["run", name]
        if let input, !input.isEmpty {
            arguments += ["--input-value", input]
        }
        let ended = await execute(arguments: arguments, capturesOutput: false)
        if let error = ShortcutRunOutcome.error(started: ended.started, timedOut: ended.timedOut, exitStatus: ended.status) {
            throw error
        }
        return ended.output
    }

    func availableShortcuts() async -> [String] {
        let ended = await execute(arguments: ["list"], capturesOutput: true)
        guard ended.started, !ended.timedOut, ended.status == 0 else { return [] }
        return ended.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private struct Ended: Sendable {
        let started: Bool
        let timedOut: Bool
        let status: Int32
        let output: String
    }

    /// `capturesOutput` is only for `list`. A run's output is never read (it could hold anything,
    /// and an unread pipe that fills would stall the Shortcut until it looked timed out), so a run
    /// writes to the null device.
    private func execute(arguments: [String], capturesOutput: Bool) async -> Ended {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = capturesOutput ? stdout : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let box = TerminationBox()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                box.finished()
                let outData = capturesOutput ? stdout.fileHandleForReading.readDataToEndOfFile() : Data()
                continuation.resume(returning: Ended(
                    started: true, timedOut: box.didTimeOut, status: proc.terminationStatus,
                    output: String(data: outData, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Ended(started: false, timedOut: false, status: -1, output: ""))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !box.isFinished else { return }
                if process.isRunning {
                    box.markTimedOut()
                    process.terminate()
                }
            }
        }
    }

    /// A tiny thread-safe flag so the timeout dispatch (fired from a background queue) can tell
    /// whether the process already finished, without capturing the non-Sendable
    /// `DispatchWorkItem`/`Process` types directly across the closure boundary.
    private final class TerminationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finishedFlag = false
        private var timedOutFlag = false
        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finishedFlag
        }
        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOutFlag
        }
        func finished() {
            lock.lock(); finishedFlag = true; lock.unlock()
        }
        func markTimedOut() {
            lock.lock(); timedOutFlag = true; lock.unlock()
        }
    }
}
