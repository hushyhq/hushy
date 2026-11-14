import Foundation
import Testing
@testable import MurmurCore

@Suite("Deep links and spoken URL policy")
struct DeepLinkBuilderTests {
    @Test func fixedHostsAndEncoding() throws {
        let gmail = try #require(DeepLinkBuilder.build(service: .gmail, action: .search, query: "a & # café"))
        #expect(gmail.url.absoluteString == "https://mail.google.com/mail/u/0/#search/a%20%26%20%23%20caf%C3%A9")
        let maps = try #require(DeepLinkBuilder.build(service: .googleMaps, action: .directions, destination: "A & B #1"))
        #expect(maps.url.host == "www.google.com")
        #expect(maps.url.query?.contains("destination=A%20%26%20B%20%231") == true)
        #expect(DeepLinkBuilder.build(service: .github, action: .issues, query: "owner/repo")?.url.absoluteString == "https://github.com/owner/repo/issues")
        #expect(DeepLinkBuilder.build(service: .github, action: .repo, query: "evil.com/x/y") == nil)
    }

    @Test func dateUsesInjectedClock() throws {
        let context = DateContext(now: ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!, timeZone: TimeZone(secondsFromGMT: 0)!)
        let link = try #require(DeepLinkBuilder.build(service: .googleCalendar, action: .day, date: "tomorrow", context: context))
        #expect(link.url.absoluteString == "https://calendar.google.com/calendar/u/0/r/day/2026/9/29")
    }

    @Test func safeURLRequiresSpokenDomain() {
        #expect(SafeURLPolicy.approvedURL("https://example.com/a", transcript: "open example dot com") != nil)
        #expect(SafeURLPolicy.approvedURL("https://evil.com", transcript: "open github") == nil)
        #expect(SafeURLPolicy.approvedURL("https://evil.com", transcript: "take a note saying open evil.com") == nil)
        for raw in ["javascript:alert(1)", "file:///tmp/a", "data:text/html,x", "http://example.com", "https://a:b@example.com", "https://127.0.0.1", "https://example.com:8443"] {
            #expect(SafeURLPolicy.approvedURL(raw, transcript: "open example dot com") == nil)
        }
        #expect(SafeURLPolicy.destination("https://evil.com", transcript: "open github")?.host == "www.google.com")
    }

    @Test func legacyCallsStayValid() {
        #expect(ToolCall(tool: "open_app", arguments: ["target": .string("Chrome")]).validationIssues().isEmpty)
        #expect(ToolCall(tool: "open_app", arguments: ["target": .string("https://github.com")]).validationIssues().isEmpty)
    }
}
