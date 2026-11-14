import Foundation
import CoreFoundation

/// One crash as MetricKit's typed properties give it (`MXCrashDiagnostic`), copied out on arrival so
/// nothing else of the payload is kept. `stackTree` is `callStackTree.jsonRepresentation()`.
struct CrashInput: Sendable, Equatable {
    var exceptionType: String?
    var exceptionCode: String?
    var signal: String?
    var terminationReason: String?
    var stackTree: Data
    var build: String?
    var os: String?
    var arch: String?
}

/// Converts crashes into the complete wire allowlist the Worker accepts (`site/worker/crash.js`).
/// The call-stack JSON is read by known shapes only: Apple has named the thread list `callStacks`,
/// `callStackThreads` and `callStackPerThread` across releases, and a frame's children `subFrames`.
enum CrashReportScrubber {
    static func report(from crashes: [CrashInput], appVersion: String, fallbackBuild: String, chip: String) -> Data? {
        let diagnostics = crashes.compactMap(scrubDiagnostic)
        guard let first = crashes.first, !diagnostics.isEmpty else { return nil }
        let report: [String: Any] = [
            "v": 1,
            "app": ["version": version(appVersion) ?? "unknown", "build": version(first.build) ?? version(fallbackBuild) ?? "unknown"],
            "os": version(first.os) ?? version(ProcessInfo.processInfo.operatingSystemVersionString) ?? "unknown",
            "arch": version(first.arch) ?? architecture,
            "chip": version(chip) ?? "unknown",
            "diagnostics": diagnostics,
        ]
        return try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }

    private static let threadListKeys = ["callStacks", "callStackThreads", "callStackPerThread"]
    private static let rootFrameKeys = ["callStackRootFrames", "rootFrames", "frames"]

    private static func scrubDiagnostic(_ crash: CrashInput) -> [String: Any]? {
        guard let tree = try? JSONSerialization.jsonObject(with: crash.stackTree) as? [String: Any],
              let threads = threadListKeys.lazy.compactMap({ tree[$0] as? [[String: Any]] }).first else { return nil }
        let cleanThreads = threads.map { thread -> [String: Any] in
            let roots = rootFrameKeys.lazy.compactMap { thread[$0] as? [[String: Any]] }.first ?? []
            return ["callStackRootFrames": roots.compactMap { frame($0, depth: 0) }]
        }
        var result: [String: Any] = ["callStackTree": ["callStackPerThread": cleanThreads]]
        let fields = [("exceptionType", crash.exceptionType), ("exceptionCode", crash.exceptionCode),
                      ("signal", crash.signal), ("terminationReason", crash.terminationReason.map(withoutPaths))]
        for (key, value) in fields { if let value = short(value) { result[key] = value } }
        return result
    }

    private static func frame(_ source: [String: Any], depth: Int) -> [String: Any]? {
        guard depth <= 32, let binary = source["binaryName"] as? String, !binary.isEmpty else { return nil }
        let name = binary.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
        guard let name, !name.isEmpty else { return nil }
        var result: [String: Any] = ["binaryName": String(name.prefix(200))]
        for key in ["offsetIntoBinaryTextSegment", "sampleCount"] {
            if let number = source[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
               number.doubleValue.rounded() == number.doubleValue { result[key] = number.int64Value }
        }
        if let children = source["subFrames"] as? [[String: Any]] {
            result["subFrames"] = children.compactMap { frame($0, depth: depth + 1) }
        }
        return result
    }

    /// A termination reason can name a file (a library that failed to load), and a path under a home
    /// folder names the person; any word with a slash or a tilde is replaced.
    static func withoutPaths(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.contains("/") || $0.contains("~") ? "[path]" : String($0) }
            .joined(separator: " ")
    }

    private static func short(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(200))
    }

    private static func version(_ value: String?) -> String? {
        guard let value = short(value),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._()-".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
