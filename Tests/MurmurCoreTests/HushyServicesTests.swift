import Foundation
import Testing
@testable import MurmurCore

struct HushyServicesTests {
    @Test func onlyTheExactOfficialValueOptsIn() {
        #expect(HushyServices(infoValue: "official") == .official)
        #expect(HushyServices(infoValue: "none") == .none)
        #expect(HushyServices(infoValue: nil) == .none)
        #expect(HushyServices(infoValue: "") == .none)
        #expect(HushyServices(infoValue: "__HUSHY_SERVICES__") == .none)
        #expect(HushyServices(infoValue: "Official") == .none)
        #expect(HushyServices(infoValue: true) == .none)
    }

    @Test func aBundleWithoutTheSettingHasNoServicesAndNoAccount() throws {
        let bundle = try Self.bundle(info: [
            "HushySupabaseURL": "https://example.supabase.co",
            "HushySupabaseAnonKey": "sb_publishable_example",
        ])
        #expect(HushyServices(bundle: bundle) == .none)
        #expect(AccountConfiguration(bundle: bundle) == nil)
    }

    @Test func anOfficialBundleWithAccountSettingsHasAnAccount() throws {
        let bundle = try Self.bundle(info: [
            "HushyServices": "official",
            "HushySupabaseURL": "https://example.supabase.co",
            "HushySupabaseAnonKey": "sb_publishable_example",
        ])
        #expect(HushyServices(bundle: bundle) == .official)
        #expect(AccountConfiguration(bundle: bundle)?.url.host == "example.supabase.co")
    }

    @Test func anOfficialBundleWithoutAccountSettingsHasNoAccount() throws {
        let bundle = try Self.bundle(info: ["HushyServices": "official", "HushySupabaseURL": "__SUPABASE_URL__"])
        #expect(AccountConfiguration(bundle: bundle) == nil)
    }

    /// A throwaway `.bundle` folder with the given Info.plist, in the temp directory.
    private static func bundle(info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-services-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "test.hushy.services.\(UUID().uuidString)"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }
}
