import Foundation
import IOKit.pwr_mgt

// The resting pill steps aside while something else is keeping the display awake for playback
// (founder decision 2026-10-29, TRY-114): a film, a call or background video in a window. We
// never read titles or URLs, only IOKit power-management assertions by process. Hushy's own
// assertions, the system's internal ones and keep-awake holders that are not playback are ignored:
// on a real Mac powerd holds an internal one, and Electron apps hold a generic one for hours.

/// One display-sleep assertion from `IOPMCopyAssertionsByProcess`.
struct PowerAssertion: Equatable, Sendable {
    let pid: Int32
    let type: String
    var name: String = ""
}

enum VideoPlayingGeometry {
    /// Assertion types that mean "don't let the display sleep yet" for playback or a call.
    static let displaySleepTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion",
        "PreventDisplaySleep",
    ]

    /// Names of holders that keep the display awake without anything playing.
    static let notPlaybackNames: Set<String> = ["electron", "caffeinate command-line tool"]

    static func isVideoPlaying(assertions: [PowerAssertion], excludingPID: Int32) -> Bool {
        assertions.contains { assertion in
            assertion.pid != excludingPID && displaySleepTypes.contains(assertion.type)
                && !notPlaybackNames.contains(assertion.name.lowercased())
        }
    }
}

struct VideoPlayingDetector {
    let isVideoPlaying: @MainActor () -> Bool

    init(isVideoPlaying: @escaping @MainActor () -> Bool) {
        self.isVideoPlaying = isVideoPlaying
    }

    static func live(excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> VideoPlayingDetector {
        VideoPlayingDetector {
            VideoPlayingGeometry.isVideoPlaying(
                assertions: LivePowerAssertions.snapshot(), excludingPID: excludingPID)
        }
    }

    static let never = VideoPlayingDetector { false }
}

@MainActor
enum LivePowerAssertions {
    /// Every live assertion, by holding process (`IOPMCopyAssertionsByProcess`: pid → [assertion]). The
    /// by-type status call (`IOPMCopyAssertionsStatus`) only gives counts, so it cannot exclude Hushy's own.
    static func snapshot() -> [PowerAssertion] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let raw = byProcess?.takeRetainedValue() as NSDictionary?
        else { return [] }
        var out: [PowerAssertion] = []
        for (key, value) in raw {
            guard let pid = (key as? NSNumber)?.int32Value, let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let type = entry[kIOPMAssertionTypeKey as String] as? String,
                      VideoPlayingGeometry.displaySleepTypes.contains(type) else { continue }
                out.append(PowerAssertion(pid: pid, type: type, name: entry[kIOPMAssertionNameKey as String] as? String ?? ""))
            }
        }
        return out
    }
}

extension Notification.Name {
    /// Posted when any process creates or releases a power assertion (`IOPMLib`).
    static let powerAssertionsChanged = Notification.Name("IOPMAssertionsChanged")
}
