import Foundation
import Testing

@testable import murmur_eval

/// Covers the pieces of the virtual-mic head-to-head kit that don't need audio hardware:
/// device-name matching, case sequencing through `HeadToHeadPlaybackSession`, and the
/// `filled.md` output format that `head-to-head build` (`HeadToHeadTemplate.parse`) reads back.
/// Playback itself (`HeadToHeadPlaybackRunner`) and the capture window's actual HTTP traffic
/// need a running audio device / socket and are exercised by the founder, not CI.
@Suite("Head-to-head device matching")
struct HeadToHeadDeviceMatchingTests {
    private let devices: [HeadToHeadDevices.OutputDevice] = [
        .init(id: 1, name: "BlackHole 2ch"),
        .init(id: 2, name: "MacBook Pro Speakers"),
        .init(id: 3, name: "External Headphones"),
    ]

    @Test func exactNameMatchWins() {
        #expect(HeadToHeadDevices.match("BlackHole 2ch", in: devices) == .found(devices[0]))
    }

    @Test func caseInsensitiveExactMatch() {
        #expect(HeadToHeadDevices.match("blackhole 2ch", in: devices) == .found(devices[0]))
    }

    @Test func substringMatchFindsTheOnlyCandidate() {
        #expect(HeadToHeadDevices.match("blackhole", in: devices) == .found(devices[0]))
        #expect(HeadToHeadDevices.match("speakers", in: devices) == .found(devices[1]))
    }

    @Test func noMatchReturnsNotFound() {
        #expect(HeadToHeadDevices.match("loopback", in: devices) == .notFound)
    }

    @Test func emptyQueryReturnsNotFound() {
        #expect(HeadToHeadDevices.match("", in: devices) == .notFound)
        #expect(HeadToHeadDevices.match("   ", in: devices) == .notFound)
    }

    @Test func ambiguousSubstringIsRejectedRatherThanGuessed() {
        let ambiguousDevices: [HeadToHeadDevices.OutputDevice] = [
            .init(id: 1, name: "BlackHole 2ch"),
            .init(id: 2, name: "BlackHole 16ch"),
        ]
        let result = HeadToHeadDevices.match("blackhole", in: ambiguousDevices)
        guard case .ambiguous(let candidates) = result else {
            Issue.record("expected .ambiguous, got \(result)")
            return
        }
        #expect(Set(candidates) == Set(ambiguousDevices))
    }

    @Test func listingFormatsEachDeviceOnItsOwnLine() {
        let text = HeadToHeadDevices.listing(devices)
        #expect(text.contains("BlackHole 2ch"))
        #expect(text.components(separatedBy: "\n").count == devices.count)
    }

    @Test func listingOfEmptyDevicesSaysSo() {
        #expect(HeadToHeadDevices.listing([]) == "No output devices found.")
    }
}

@Suite("Head-to-head playback session sequencing")
struct HeadToHeadPlaybackSessionTests {
    private func session(_ ids: [String] = ["p-001", "p-002", "p-003"]) -> HeadToHeadPlaybackSession {
        HeadToHeadPlaybackSession(cases: ids.map { .init(id: $0, audioPath: "/tmp/\($0).wav") })
    }

    @Test func startsAtTheFirstCase() {
        let session = session()
        #expect(session.currentCase?.id == "p-001")
        #expect(session.remaining == 3)
        #expect(!session.isFinished)
    }

    @Test func capturedTextAdvancesAndTrims() {
        var session = session()
        let action = session.handle(.textCaptured("  hello there  \n"))
        #expect(action == .saveAndAdvance(caseID: "p-001", text: "hello there"))
        #expect(session.currentCase?.id == "p-002")
        #expect(session.remaining == 2)
    }

    @Test func skipRecordsEmptyAndAdvances() {
        var session = session()
        let action = session.handle(.skip)
        #expect(action == .advanceEmpty(caseID: "p-001"))
        #expect(session.currentCase?.id == "p-002")
    }

    @Test func silenceTimeoutRecordsEmptyAndAdvances() {
        var session = session()
        let action = session.handle(.silenceTimeout)
        #expect(action == .advanceEmpty(caseID: "p-001"))
    }

    @Test func whitespaceOnlyCaptureCountsAsEmpty() {
        var session = session()
        let action = session.handle(.textCaptured("   \n\t  "))
        #expect(action == .advanceEmpty(caseID: "p-001"))
    }

    @Test func finishesAfterTheLastCase() {
        var session = session(["p-001"])
        _ = session.handle(.textCaptured("only one"))
        #expect(session.isFinished)
        #expect(session.currentCase == nil)
        #expect(session.remaining == 0)
    }

    @Test func resultsPreserveCaseOrderRegardlessOfEventType() {
        var session = session()
        _ = session.handle(.textCaptured("first"))
        _ = session.handle(.skip)
        _ = session.handle(.textCaptured("third"))
        #expect(session.results.map(\.caseID) == ["p-001", "p-002", "p-003"])
        #expect(session.results.map(\.text) == ["first", "", "third"])
    }

    @Test func emptyCaseListStartsFinished() {
        let session = session([])
        #expect(session.isFinished)
        #expect(session.currentCase == nil)
    }
}

@Suite("Head-to-head filled.md output format")
struct HeadToHeadFilledMarkdownTests {
    @Test func rendersOneHeadingPerCaseWithBodyText() {
        var session = HeadToHeadPlaybackSession(cases: [
            .init(id: "p-001", audioPath: "/a.wav"),
            .init(id: "p-002", audioPath: "/b.wav"),
        ])
        _ = session.handle(.textCaptured("Hello, this is the first paragraph."))
        _ = session.handle(.textCaptured("And the second one, right here."))
        let markdown = session.renderFilledMarkdown(product: "Wispr Flow")
        #expect(markdown.contains("## p-001"))
        #expect(markdown.contains("## p-002"))
        #expect(markdown.contains("Hello, this is the first paragraph."))
        #expect(markdown.contains("And the second one, right here."))
    }

    @Test func roundTripsThroughHeadToHeadTemplateParse() {
        var session = HeadToHeadPlaybackSession(cases: [
            .init(id: "p-001", audioPath: "/a.wav"),
            .init(id: "p-002", audioPath: "/b.wav"),
            .init(id: "p-003", audioPath: "/c.wav"),
        ])
        _ = session.handle(.textCaptured("First captured paragraph, as pasted."))
        _ = session.handle(.skip)
        _ = session.handle(.textCaptured("Third captured paragraph, multi\nline even."))
        let markdown = session.renderFilledMarkdown(product: "Wispr Flow")

        let parsed = HeadToHeadTemplate.parse(markdown)
        #expect(parsed.outputs["p-001"] == "First captured paragraph, as pasted.")
        #expect(parsed.outputs["p-003"] == "Third captured paragraph, multi\nline even.")
        #expect(parsed.outputs["p-002"] == nil)
        #expect(parsed.emptySlots == ["p-002"])
    }

    @Test func filledMarkdownFromOneSideBuildsPairsWithATemplateRenderedHushySide() {
        // Simulates the real workflow: hushy.md comes from `head-to-head template` + manual
        // dictation (rendered via `HeadToHeadTemplate.render`/typed in by hand, parsed back the
        // same way), and wispr-flow.md comes from `head-to-head play`'s captured output. Both
        // must parse to the same slot ids so `build` can pair them.
        let slots = HeadToHeadTemplate.plan(count: 3)
        var hushyDoc = HeadToHeadTemplate.render(slots: slots, product: "Hushy")
        for slot in slots {
            hushyDoc = hushyDoc.replacingOccurrences(
                of: "## \(slot.id) · \(slot.style.rawValue) · \(slot.isLong ? "LONG (over 60 s)" : "short (10–40 s)")\n<!-- \(slot.style.cue) -->\n\n",
                with: "## \(slot.id) · \(slot.style.rawValue) · \(slot.isLong ? "LONG (over 60 s)" : "short (10–40 s)")\n<!-- \(slot.style.cue) -->\n\nHushy output for \(slot.id)\n")
        }
        let hushyParsed = HeadToHeadTemplate.parse(hushyDoc)

        var session = HeadToHeadPlaybackSession(cases: slots.map { .init(id: $0.id, audioPath: "/\($0.id).wav") })
        for slot in slots { _ = session.handle(.textCaptured("Wispr output for \(slot.id)")) }
        let wisprDoc = session.renderFilledMarkdown(product: "Wispr Flow")
        let wisprParsed = HeadToHeadTemplate.parse(wisprDoc)

        let result = HeadToHeadTemplate.build(hushy: hushyParsed, other: wisprParsed, otherName: "Wispr Flow")
        #expect(result.pairs.count == 3)
        #expect(result.missingHushy.isEmpty)
        #expect(result.missingOther.isEmpty)
        for pair in result.pairs {
            #expect(pair.hushyOutput == "Hushy output for \(pair.id)")
            #expect(pair.otherOutput == "Wispr output for \(pair.id)")
        }
    }

    @Test func staticRenderFilledMarkdownMatchesInstanceMethod() {
        let results = [
            HeadToHeadPlaybackSession.Result(caseID: "p-001", text: "alpha"),
            HeadToHeadPlaybackSession.Result(caseID: "p-002", text: "beta"),
        ]
        let markdown = HeadToHeadPlaybackSession.renderFilledMarkdown(results, product: "Wispr Flow")
        let parsed = HeadToHeadTemplate.parse(markdown)
        #expect(parsed.outputs["p-001"] == "alpha")
        #expect(parsed.outputs["p-002"] == "beta")
    }
}

@Suite("Head-to-head capture HTTP parsing")
struct HeadToHeadCaptureHTTPTests {
    @Test func parsesAGetRequestWithNoBody() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:5123\r\n\r\n"
        let request = CaptureHTTP.parse(Data(raw.utf8))
        #expect(request?.method == "GET")
        #expect(request?.path == "/")
        #expect(request?.host == "127.0.0.1:5123")
        #expect(request?.body.isEmpty == true)
    }

    @Test func parsesAPostRequestWithBody() {
        let body = "Hello, this is the captured text."
        let raw = "POST /event HTTP/1.1\r\nHost: 127.0.0.1:5123\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = CaptureHTTP.parse(Data(raw.utf8))
        #expect(request?.method == "POST")
        #expect(request?.path == "/event")
        #expect(String(data: request?.body ?? Data(), encoding: .utf8) == body)
    }

    @Test func returnsNilUntilTheFullBodyArrives() {
        let raw = "POST /event HTTP/1.1\r\nHost: 127.0.0.1:5123\r\nContent-Length: 20\r\n\r\nshort"
        #expect(CaptureHTTP.parse(Data(raw.utf8)) == nil)
    }

    @Test func returnsNilForAnIncompleteHead() {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:5123"
        #expect(CaptureHTTP.parse(Data(raw.utf8)) == nil)
    }

    @Test func isLoopbackAcceptsOnlyTheExpectedHostAndPort() {
        #expect(CaptureHTTP.isLoopback("127.0.0.1:5123", port: 5123))
        #expect(CaptureHTTP.isLoopback("localhost:5123", port: 5123))
        #expect(!CaptureHTTP.isLoopback("127.0.0.1:9999", port: 5123))
        #expect(!CaptureHTTP.isLoopback("evil.example.com:5123", port: 5123))
        #expect(!CaptureHTTP.isLoopback(nil, port: 5123))
    }

    @Test func jsonStringEscapesQuotesBackslashesAndNewlines() {
        #expect(CaptureHTTP.jsonString("he said \"hi\"\\n") == "\"he said \\\"hi\\\"\\\\n\"")
    }
}
