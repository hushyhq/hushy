#if DEBUG
import Foundation
import MurmurCore

/// Process exit codes of the headless mock-microphone mode. Distinct so a script can tell
/// "the device is missing" from "a scenario failed".
enum MockMicExit {
    static let ok: Int32 = 0
    static let failed: Int32 = 1
    static let usage: Int32 = 2
    static let refused: Int32 = 3
    /// The capture came back all zeros: a microphone-permission block. Nothing else is attempted.
    static let blocked: Int32 = 4
    static let skipped: Int32 = 77
}

/// Safety rule 1: never run against the founder's real data folder.
enum MockMicHome {
    enum Verdict: Equatable {
        case allowed(String)
        case refused(String)
    }

    /// The folder this mode must never touch: `~/Library/Application Support/Hushy`.
    static var realSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.appName, isDirectory: true)
    }

    /// `HUSHY_HOME` / `MURMUR_HOME` must be set, and neither may be the real Application Support
    /// folder, a folder inside it, or a folder that contains it (so `~` and `/` are refused too).
    static func evaluate(environment: [String: String], realSupport: URL) -> Verdict {
        let names = ["HUSHY_HOME", "MURMUR_HOME"]
        let values = names.compactMap { name in environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        guard let first = values.first else {
            return .refused("Set HUSHY_HOME (or MURMUR_HOME) to a throwaway folder first; this mode never runs on the real data folder.")
        }
        let real = normalized(realSupport.path)
        for value in values where overlapsReal(normalized(value), real: real) {
            return .refused("\(value) is, contains or is inside the real Hushy data folder; use a throwaway folder.")
        }
        return .allowed(first)
    }

    private static func normalized(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func overlapsReal(_ candidate: String, real: String) -> Bool {
        if candidate == real || candidate == "/" { return true }
        return candidate.hasPrefix(real + "/") || real.hasPrefix(candidate + "/")
    }
}

/// An audio input device as the harness sees it, from its own CoreAudio query.
struct MockMicDevice: Equatable {
    let id: UInt32
    let name: String
    let isVirtual: Bool
    let inputChannels: Int
}

/// Safety rule 2: only a virtual BlackHole input is ever opened.
enum MockMicDeviceRule {
    /// The one device the playback utility can play into (`tools/audio-loopback` matches this name exactly).
    static let playerDeviceName = "BlackHole 2ch"

    enum Decision: Equatable {
        case use(MockMicDevice)
        case skip(String)
    }

    static func decide(_ devices: [MockMicDevice]) -> Decision {
        let eligible = devices.filter { $0.name.hasPrefix("BlackHole") && $0.isVirtual && $0.inputChannels > 0 }
        guard !eligible.isEmpty else {
            return .skip("No virtual BlackHole input device is installed, so there is nothing safe to record from.")
        }
        guard let device = eligible.first(where: { $0.name == playerDeviceName }) else {
            return .skip("Only a BlackHole variant other than \"\(playerDeviceName)\" is present, and the player can only play into the 2ch one.")
        }
        return .use(device)
    }
}
#endif
