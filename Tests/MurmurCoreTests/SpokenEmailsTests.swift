import XCTest
@testable import MurmurCore

final class SpokenEmailsTests: XCTestCase {
    func testSpokenEmailsAreJoined() {
        let cases: [(String, String)] = [
            ("send the invite to john at gmail dot com", "send the invite to john@gmail.com"),
            ("Send the invite to John at gmail.com.", "Send the invite to john@gmail.com."),
            ("Send the invite to John at @gmail.com.", "Send the invite to john@gmail.com."),
            ("write to ada at tryhushy dot com please", "write to ada@tryhushy.com please"),
            ("cc ada at example dot co dot uk", "cc ada@example.co.uk"),
            ("my address is sam99 at outlook dot com", "my address is sam99@outlook.com"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenEmails.apply(input), expected, input)
        }
    }

    /// Ordinary speech with "at" is never an address, with or without a dot after it.
    func testOrdinarySpeechIsLeftAlone() {
        let sentences = [
            "meet me at the station dot",
            "I'm at home",
            "email me at noon",
            "we met at 5 dot",
            "Meet me at starbucks.com tomorrow",
            "I'll see you at acme.com",
            "look at gmail dot com for the invite",
            "she is at example dot com",
            "I arrived at google.com yesterday",
            "the meeting is at 3.30 in the lab",
            "great at gmail dot org",
            "it is good at it. Com later",
        ]
        for sentence in sentences {
            XCTAssertEqual(SpokenEmails.apply(sentence), sentence, sentence)
        }
    }

    func testAnOrdinaryWordIsAMailboxOnlyAtAMailProvider() {
        XCTAssertEqual(SpokenEmails.apply("send it to sales at gmail.com"), "send it to sales@gmail.com")
        XCTAssertEqual(SpokenEmails.apply("send it to sales at acme.com"), "send it to sales at acme.com")
        XCTAssertEqual(SpokenEmails.apply("send it to Priya at acme.com"), "send it to priya@acme.com")
        XCTAssertEqual(SpokenEmails.apply("send it to sales at acme dot com"), "send it to sales@acme.com")
    }

    func testAnAddressIsJoinedOnce() {
        XCTAssertEqual(SpokenEmails.apply("john@gmail.com"), "john@gmail.com")
        XCTAssertEqual(SpokenEmails.apply(SpokenEmails.apply("john at gmail dot com")), "john@gmail.com")
    }
}
