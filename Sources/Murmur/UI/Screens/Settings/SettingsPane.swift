import Foundation
import MurmurCore

/// One pane in the Settings window's left sidebar. Six are always there, in the order a person
/// needs them: General and Privacy cover everything most people ever change; Voice actions is the
/// beta; Account, About and Advanced are opened rarely. The experience plan of 2026-10-25 (section
/// 3.2) maps every control to one of them.
///
/// `notesAndMeetings` is the frozen part of the app: it appears only while Advanced →
/// "Notes and meetings (preview)" is on. `developer` exists in debug builds only.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, privacy, voiceActions, notesAndMeetings, account, about, advanced
    #if DEBUG
    case developer
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .voiceActions: "Voice actions · beta"
        case .notesAndMeetings: "Notes & meetings"
        case .account: "Account"
        case .about: "About"
        case .advanced: "Advanced"
        #if DEBUG
        case .developer: "Developer"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "lock.shield"
        case .voiceActions: "bolt"
        case .notesAndMeetings: "note.text"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        case .advanced: "slider.horizontal.3"
        #if DEBUG
        case .developer: "hammer"
        #endif
        }
    }

    /// The panes in the sidebar. `showsNotesAndMeetings` is `AppSettings.notesAndMeetingsPreview`.
    /// Release builds never list Notes & meetings (`FeatureFlags.meetings`), whatever it says.
    static func visible(showsNotesAndMeetings: Bool, meetings: Bool = FeatureFlags.meetings) -> [SettingsPane] {
        allCases.filter { $0 != .notesAndMeetings || (showsNotesAndMeetings && meetings) }
    }

    /// The pane a value saved by an earlier version of the window belongs to. Ten panes became six,
    /// so the old names map to where their controls went; nil for a name that never existed.
    init?(savedValue: String) {
        if let pane = SettingsPane(rawValue: savedValue) { self = pane; return }
        switch savedValue {
        case "system", "writing": self = .general
        case "privacySecurity": self = .privacy
        case "pro": self = .account
        case "meetings", "voices": self = .notesAndMeetings
        case "aiConnections": self = .advanced
        default: return nil
        }
    }
}
