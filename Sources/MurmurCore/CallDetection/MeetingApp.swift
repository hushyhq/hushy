import Foundation

/// A video/audio-calling app Hushy can recognize by bundle id and offer to record notes for.
/// Core Audio establishes mic use before the DEBUG-only browser-title service hint is read.
/// This type maps a bundle id to a display name and classifies those title hints.
///
/// Browser-hosted calls (Meet or Teams in a tab) have no separate app bundle id of their own —
/// the mic user is the browser itself — so `matching(bundleID:)` maps every common desktop
/// browser to `.browserMeeting`, a generic fallback when the service is unknown.
public enum MeetingApp: String, Sendable, Equatable, Codable, CaseIterable {
    case zoom
    case teams
    case webex
    case faceTime
    case slackHuddle
    case discord
    case browserMeeting

    /// Shown in the call-detected prompt and the note's meta line ("Today · 32 min · Zoom").
    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .webex: "Webex"
        case .faceTime: "FaceTime"
        case .slackHuddle: "Slack"
        case .discord: "Discord"
        case .browserMeeting: "Meeting"
        }
    }

    /// Bundle ids this app is known to run under. Kept as a list (rather than one id) since some
    /// of these ship multiple bundle ids across their update channels (e.g. Zoom's client vs. its
    /// helper processes) or across Intel/Apple Silicon-era installers.
    var bundleIDs: Set<String> {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
        case .faceTime: ["com.apple.FaceTime"]
        case .slackHuddle: ["com.tinyspeck.slackmacgap"]
        case .discord: ["com.hnc.Discord"]
        case .browserMeeting: [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        ]
        }
    }

    /// Every bundle id this module recognizes, mapped back to its `MeetingApp` — built once,
    /// not per lookup, since `matching(bundleID:)` runs on every mic-use poll while a note isn't
    /// already recording.
    private static let byBundleID: [String: MeetingApp] = {
        var map: [String: MeetingApp] = [:]
        for app in MeetingApp.allCases {
            for id in app.bundleIDs { map[id] = app }
        }
        return map
    }()

    /// The `MeetingApp` matching `bundleID`, or `nil` if it isn't one Hushy recognizes. Bundle id
    /// comparison is case-insensitive (Core Audio/NSWorkspace bundle ids are reverse-DNS and
    /// case-sensitive in practice, but this costs nothing and avoids a class of near-miss bugs).
    public static func matching(bundleID: String) -> MeetingApp? {
        byBundleID[bundleID] ?? byBundleID.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    /// A browser window title is only a service hint. The caller must independently verify
    /// that this browser is using the microphone before treating it as an active call.
    public static func browserMeeting(windowTitle: String) -> MeetingApp? {
        let title = windowTitle.lowercased()
        if title.contains("google meet") || title.contains("meet.google.com")
            || title.hasPrefix("meet - ") || title.contains(" - meet - ") { return .browserMeeting }
        if title.contains("microsoft teams") || title.contains("teams.microsoft.com") { return .teams }
        if title.contains("join zoom meeting") || title.contains("zoom meeting") || title.contains("zoom.us") { return .zoom }
        return nil
    }
}
