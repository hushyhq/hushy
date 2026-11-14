#if DEBUG
import AppKit
import Foundation

/// What the command line asked for. Parsed on its own so it can be tested without a device.
struct MockMicArguments: Equatable {
    enum Mode: Equatable {
        /// `--mock-mic <report-dir>`: run the scenarios.
        case run(report: String)
        /// `--mock-mic-jobs <work-dir>`: write the `say` job list for the driver script.
        case jobs(work: String)
        /// `--mock-mic-assemble <work-dir>`: build the meeting clips and `clips.json` from the spoken parts.
        case assemble(work: String)
    }

    let mode: Mode
    let clips: String?
    let player: String?

    static func requested(_ arguments: [String]) -> Bool {
        arguments.contains { ["--mock-mic", "--mock-mic-jobs", "--mock-mic-assemble"].contains($0) }
    }

    /// `nil` when the flags are unusable (missing value, or more than one mode).
    static func parse(_ arguments: [String]) -> MockMicArguments? {
        func value(_ flag: String) -> String?? {
            guard let index = arguments.firstIndex(of: flag) else { return .none }
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { return .some(nil) }
            return .some(arguments[index + 1])
        }
        var modes: [Mode] = []
        for (flag, make) in [("--mock-mic", { Mode.run(report: $0) }), ("--mock-mic-jobs", { Mode.jobs(work: $0) }),
                             ("--mock-mic-assemble", { Mode.assemble(work: $0) })] as [(String, (String) -> Mode)] {
            switch value(flag) {
            case .none: continue
            case .some(nil): return nil
            case .some(let path?): modes.append(make(path))
            }
        }
        guard modes.count == 1, let mode = modes.first else { return nil }
        guard case .some(let clips) = value("--clips") ?? .some(nil), case .some(let player) = value("--player") ?? .some(nil) else { return nil }
        return MockMicArguments(mode: mode, clips: clips, player: player)
    }
}

/// The headless entry point: no `NSApplication`, so no window, menu bar item, dock icon, hotkey monitor
/// or event tap can exist. The main run loop is kept alive by a timer so `NoteRecorder`'s own timers fire.
@MainActor
enum MockMicLauncher {
    static func launch(_ arguments: [String]) -> Never {
        guard let parsed = MockMicArguments.parse(arguments) else {
            fail("usage: Murmur --mock-mic <report-dir> [--clips <dir>] [--player <path>]", MockMicExit.usage)
        }
        Task { @MainActor in exit(await execute(parsed)) }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.run()
        exit(MockMicExit.failed)
    }

    private static func fail(_ message: String, _ code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func execute(_ arguments: MockMicArguments, environment: [String: String] = ProcessInfo.processInfo.environment,
                        realSupport: URL = MockMicHome.realSupport) async -> Int32 {
        if let reason = MockMicRun.homeRefusal(environment: environment, realSupport: realSupport) {
            FileHandle.standardError.write(Data("mock-mic: refused: \(reason)\n".utf8))
            return MockMicExit.refused
        }
        do {
            switch arguments.mode {
            case .jobs(let work): return try MockMicWorkdir.writeJobs(to: URL(fileURLWithPath: work))
            case .assemble(let work): return try MockMicWorkdir.assemble(in: URL(fileURLWithPath: work))
            case .run(let report): return await MockMicRun.run(report: URL(fileURLWithPath: report), arguments: arguments)
            }
        } catch {
            FileHandle.standardError.write(Data("mock-mic: \(error)\n".utf8))
            return MockMicExit.failed
        }
    }
}
#endif
