import EventKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// "Name notes from your calendar" (Settings → Meetings): defaults to whatever calendar access
/// already exists, persists an explicit choice, asks macOS only when the user turns it on and it
/// can still ask, and says in one line how to allow access after a refusal. No real calendar.
@Suite("Name notes from your calendar — setting")
@MainActor
struct CalendarNamingSettingTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "hushy-test-calendar-naming-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("defaults ON when calendar access was already granted, for example through voice actions")
    func defaultsOnWithAccess() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppSettings(defaults: defaults, calendarAuthorization: .fullAccess).nameNotesFromCalendar)
    }

    @Test("defaults OFF with no access, a refusal, a restriction or write-only access")
    func defaultsOffWithoutAccess() {
        for status in [CalendarAuthorization.notDetermined, .denied, .restricted, .writeOnly] {
            let (defaults, name) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            #expect(!AppSettings(defaults: defaults, calendarAuthorization: status).nameNotesFromCalendar)
        }
    }

    @Test("an explicit choice persists and beats the access-based default")
    func explicitChoiceWins() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        AppSettings(defaults: defaults, calendarAuthorization: .fullAccess).nameNotesFromCalendar = false
        #expect(!AppSettings(defaults: defaults, calendarAuthorization: .fullAccess).nameNotesFromCalendar)
        AppSettings(defaults: defaults, calendarAuthorization: .denied).nameNotesFromCalendar = true
        #expect(AppSettings(defaults: defaults, calendarAuthorization: .denied).nameNotesFromCalendar)
    }

    @Test("turning it on asks macOS the first time, and turns on only if the answer is yes")
    func turnOnAsksOnce() async {
        let granting = StaticCalendarReader(authorization: .notDetermined, grantsOnRequest: true)
        let granted = await CalendarNamingSetting.turnOn(reader: granting)
        #expect(granted == CalendarNamingSetting.Outcome(isOn: true, access: .fullAccess))
        #expect(await granting.requestCount == 1)

        let refusing = StaticCalendarReader(authorization: .notDetermined, grantsOnRequest: false)
        let refused = await CalendarNamingSetting.turnOn(reader: refusing)
        #expect(refused == CalendarNamingSetting.Outcome(isOn: false, access: .denied))
    }

    @Test("turning it on never shows the prompt when access is already decided")
    func turnOnDoesNotReprompt() async {
        let already = StaticCalendarReader(authorization: .fullAccess)
        #expect(await CalendarNamingSetting.turnOn(reader: already).isOn)
        #expect(await already.requestCount == 0)
        for status in [CalendarAuthorization.denied, .restricted, .writeOnly] {
            let reader = StaticCalendarReader(authorization: status)
            let outcome = await CalendarNamingSetting.turnOn(reader: reader)
            #expect(!outcome.isOn)
            #expect(outcome.access == status)
            #expect(await reader.requestCount == 0)
        }
    }

    @Test("a refusal or restriction explains in one line where to allow access")
    func deniedMessage() {
        for status in [CalendarAuthorization.denied, .restricted, .writeOnly] {
            let detail = CalendarNamingSetting.detail(for: status)
            #expect(detail.contains("System Settings"))
            #expect(detail.contains("Calendars"))
            #expect(!detail.contains("\n"))
        }
        #expect(!CalendarNamingSetting.detail(for: .fullAccess).contains("System Settings"))
        #expect(!CalendarNamingSetting.detail(for: .notDetermined).contains("System Settings"))
    }

    @Test("only a refusal, a restriction or write-only access offers the System Settings button")
    func settingsButtonOnlyWhenBlocked() {
        #expect(CalendarNamingSetting.offersSystemSettings(for: .denied))
        #expect(CalendarNamingSetting.offersSystemSettings(for: .restricted))
        #expect(CalendarNamingSetting.offersSystemSettings(for: .writeOnly))
        #expect(!CalendarNamingSetting.offersSystemSettings(for: .fullAccess))
        #expect(!CalendarNamingSetting.offersSystemSettings(for: .notDetermined))
    }
}

/// The pure EventKit-to-Hushy status mappings. The `EKEvent` copy itself is not unit-tested: building
/// one needs a live event store, which this suite never opens.
@Suite("EventKit calendar reader — mappings")
struct EventKitCalendarReaderMappingTests {
    @Test("authorization status maps one to one")
    func authorization() {
        #expect(EventKitCalendarReader.authorization(from: .notDetermined) == .notDetermined)
        #expect(EventKitCalendarReader.authorization(from: .restricted) == .restricted)
        #expect(EventKitCalendarReader.authorization(from: .denied) == .denied)
        #expect(EventKitCalendarReader.authorization(from: .writeOnly) == .writeOnly)
        #expect(EventKitCalendarReader.authorization(from: .fullAccess) == .fullAccess)
    }

    @Test("participant status maps to the attendee status")
    func participantStatus() {
        #expect(EventKitCalendarReader.status(from: .accepted) == .accepted)
        #expect(EventKitCalendarReader.status(from: .declined) == .declined)
        #expect(EventKitCalendarReader.status(from: .tentative) == .tentative)
        #expect(EventKitCalendarReader.status(from: .pending) == .pending)
        #expect(EventKitCalendarReader.status(from: .unknown) == .unknown)
        #expect(EventKitCalendarReader.status(from: .delegated) == .unknown)
    }

    @Test("an email address is read from a mailto participant URL, and only from one")
    func mailtoAddress() {
        #expect(EventKitCalendarReader.emailAddress(from: URL(string: "mailto:dana@example.com")) == "dana@example.com")
        #expect(EventKitCalendarReader.emailAddress(from: URL(string: "mailto:dana@example.com?subject=hi")) == "dana@example.com")
        #expect(EventKitCalendarReader.emailAddress(from: URL(string: "https://example.com/p/1")) == nil)
        #expect(EventKitCalendarReader.emailAddress(from: nil) == nil)
    }
}
