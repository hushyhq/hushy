import Foundation
import Testing
@testable import Murmur

/// The "is Sparkle configured in this build?" rule: placeholders, blanks, non-https feeds and
/// malformed keys all mean inert — the app then says "Updates aren't configured in this build".
@Suite("Update feed configuration")
struct UpdateFeedConfigurationTests {
    private let validKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test("placeholders from Info.plist are not a configuration")
    func placeholders() {
        let config = UpdateFeedConfiguration(feedURL: "__APPCAST_URL__", publicKey: "__SPARKLE_ED_PUBLIC_KEY__")
        #expect(!config.isConfigured)
        #expect(config.feedURL == nil)
        #expect(config.publicKey == nil)
    }

    @Test("empty or missing values are not a configuration")
    func empty() {
        #expect(!UpdateFeedConfiguration(feedURL: "", publicKey: "").isConfigured)
        #expect(!UpdateFeedConfiguration(feedURL: nil, publicKey: nil).isConfigured)
        #expect(!UpdateFeedConfiguration(infoDictionary: [:]).isConfigured)
        #expect(!UpdateFeedConfiguration(infoDictionary: nil).isConfigured)
    }

    @Test("a real https feed plus a 32-byte base64 key is configured")
    func configured() {
        let config = UpdateFeedConfiguration(feedURL: "https://updates.example.com/appcast.xml", publicKey: validKey)
        #expect(config.isConfigured)
        #expect(config.feedURL?.host == "updates.example.com")
    }

    @Test("http feeds and short keys are rejected")
    func rejected() {
        #expect(!UpdateFeedConfiguration(feedURL: "http://updates.example.com/appcast.xml", publicKey: validKey).isConfigured)
        #expect(!UpdateFeedConfiguration(feedURL: "https://updates.example.com/appcast.xml", publicKey: "not base64!").isConfigured)
        let shortKey = Data(repeating: 1, count: 16).base64EncodedString()
        #expect(!UpdateFeedConfiguration(feedURL: "https://updates.example.com/appcast.xml", publicKey: shortKey).isConfigured)
    }

    @Test("reads the Sparkle keys from an Info.plist dictionary")
    func fromInfoDictionary() {
        let info: [String: Any] = ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": validKey]
        #expect(UpdateFeedConfiguration(infoDictionary: info).isConfigured)
    }
}
