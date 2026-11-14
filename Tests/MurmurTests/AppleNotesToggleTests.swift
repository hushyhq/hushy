import Foundation
import MurmurCore
import Testing

@testable import Murmur

/// The "turn on → check access → notice or keep" logic shared by the four Apple Notes toggles
/// (setup choice, Notes sidebar, Settings → Meetings, Settings → Voice actions). Everything goes
/// through the fake scripter and a private settings store: no AppleScript, no Automation prompt,
/// no real Notes, no standard defaults.
@MainActor
@Suite("Apple Notes toggle", .serialized, .timeLimit(.minutes(1)))
struct AppleNotesToggleTests {
    private func freshSettings() -> AppSettings {
        let name = "app.hushy.tests.notestoggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppSettings(defaults: defaults, calendarAuthorization: .denied)
    }

    private func refusal(_ number: Int) -> FakeAppleNotesScripter {
        FakeAppleNotesScripter(error: .init(number: number, message: "refused"))
    }

    /// The two settings the Settings panes bind: where "save" and "search" live.
    struct Target: Sendable, CustomTestStringConvertible {
        let name: String
        let read: @MainActor (AppSettings) -> Bool
        let write: @MainActor (AppSettings, Bool) -> Void
        var testDescription: String { name }
    }

    nonisolated static let targets = [
        Target(name: "Meetings: save notes", read: { $0.saveNotesToAppleNotes }, write: { $0.saveNotesToAppleNotes = $1 }),
        Target(name: "Voice actions: search notes", read: { $0.searchAppleNotes }, write: { $0.searchAppleNotes = $1 }),
    ]

    @Test("granted turns the setting on with no notice", arguments: targets)
    func granted(_ target: Target) {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        toggle.turn(true, using: FakeAppleNotesScripter()) { target.write(settings, $0) }
        #expect(target.read(settings))
        #expect(toggle.problem == nil)
    }

    @Test("macOS refusing keeps it off and shows the blocked notice with System Settings", arguments: targets)
    func blocked(_ target: Target) {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        toggle.turn(true, using: refusal(-1743)) { target.write(settings, $0) }
        #expect(!target.read(settings))
        #expect(toggle.problem == .notPermitted)
        #expect(toggle.problem?.canOpenSettings == true)
        #expect(toggle.problem?.message.contains("macOS blocked it") == true)
    }

    @Test("a timeout or Notes being unavailable keeps it off with its own sentence, no System Settings", arguments: targets)
    func otherRefusals(_ target: Target) {
        for (number, expected) in [(-1712, AppleNotesAccessResult.timedOut), (-600, .notesUnavailable), (-128, .other(-128))] {
            let settings = freshSettings()
            let toggle = AppleNotesToggle()
            toggle.turn(true, using: refusal(number)) { target.write(settings, $0) }
            #expect(!target.read(settings))
            #expect(toggle.problem == expected)
            #expect(toggle.problem?.message == expected.message)
            #expect(toggle.problem?.canOpenSettings == false)
            #expect(toggle.problem?.message.contains("blocked") == false)
        }
    }

    @Test("Try again re-checks and turns it on once access is granted", arguments: targets)
    func tryAgain(_ target: Target) {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        let scripter = refusal(-1743)
        toggle.turn(true, using: scripter) { target.write(settings, $0) }
        #expect(!target.read(settings))
        scripter.error = nil
        toggle.turn(true, using: scripter) { target.write(settings, $0) }
        #expect(target.read(settings))
        #expect(toggle.problem == nil)
        #expect(scripter.sources.count == 2)
    }

    @Test("turning it off never calls the scripting double and clears the notice", arguments: targets)
    func off(_ target: Target) {
        let settings = freshSettings()
        let toggle = AppleNotesToggle()
        let scripter = refusal(-1743)
        toggle.turn(true, using: scripter) { target.write(settings, $0) }
        #expect(toggle.problem != nil)
        let before = scripter.sources.count
        toggle.turn(false, using: scripter) { target.write(settings, $0) }
        #expect(scripter.sources.count == before)
        #expect(!target.read(settings))
        #expect(toggle.problem == nil)
    }

    @Test("turning it on runs one read-only script")
    func readOnlyCheck() {
        let scripter = FakeAppleNotesScripter()
        AppleNotesToggle().turn(true, using: scripter) { _ in }
        #expect(scripter.sources.count == 1)
        #expect(!scripter.sources[0].contains("make new"))
    }
}
