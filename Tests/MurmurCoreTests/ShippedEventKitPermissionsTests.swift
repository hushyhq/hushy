import Foundation
import Testing

/// The signed app bundle (`scripts/build-app.sh` → `Resources/Murmur.entitlements` and
/// `Resources/Info.plist`). EventKit voice actions and calendar reads fail under hardened runtime
/// without the personal-information entitlements even when TCC usage strings are present.
@Suite("Shipped EventKit permissions manifest")
struct ShippedEventKitPermissionsTests {
    private static let calendarEntitlement = "com.apple.security.personal-information.calendars"
    private static let calendarUsageKey = "NSCalendarsFullAccessUsageDescription"
    private static let remindersUsageKey = "NSRemindersFullAccessUsageDescription"

    @Test("entitlements and Info.plist cover calendar and reminders EventKit access")
    func manifest() throws {
        let root = try repositoryRoot()
        let entitlements = try loadPlist(at: root.appendingPathComponent("Resources/Murmur.entitlements"))
        #expect(entitlements[Self.calendarEntitlement] as? Bool == true)
        // Hardened runtime defines no reminders entitlement; an unknown key could break signing.
        #expect(entitlements["com.apple.security.personal-information.reminders"] == nil)

        let info = try loadPlist(at: root.appendingPathComponent("Resources/Info.plist"))
        let calendarUsage = try #require(info[Self.calendarUsageKey] as? String)
        let remindersUsage = try #require(info[Self.remindersUsageKey] as? String)
        #expect(!calendarUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!remindersUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let buildScript = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(buildScript.contains("Resources/Murmur.entitlements"))
        #expect(buildScript.contains("Resources/Info.plist"))
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) else {
            struct MissingRepo: Error {}
            throw MissingRepo()
        }
        return url
    }

    private func loadPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }
}
