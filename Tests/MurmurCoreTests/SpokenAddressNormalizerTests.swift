import XCTest
@testable import MurmurCore

final class SpokenAddressNormalizerTests: XCTestCase {
    func testAddresses() {
        let cases: [(String, String)] = [
            ("blog dot tryhushy dot com", "blog.tryhushy.com"),
            ("blog, tryhushy.com", "blog.tryhushy.com"),
            ("try hushy dot com", "tryhushy.com"),
            ("Tryhashi. Com", "tryhushy.com"),
            ("check out github dot com slash anthropics", "check out github.com/anthropics"),
            ("email me at ada at tryhushy dot com", "email me at ada@tryhushy.com"),
            ("go to w w w dot apple dot com", "go to www.apple.com"),
            ("Visit TRYHUSHY.COM.", "Visit tryhushy.com."),
            ("https colon slash slash example dot org", "https://example.org"),
            ("AcMe dot Co dot Uk", "acme.co.uk")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenAddressNormalizer.apply(input), expected, input)
        }
    }

    func testOrdinarySpeechStaysOrdinary() {
        let negatives = [
            "connect the dots", "polka dot dress", "dot the i", "dot matrix printer",
            "I work at a startup. Co-founders are here", "I work at a startup. So do they",
            "the app is ready. Developer tools follow", "come in. Under the bridge",
            "please do. Come back", "I am at home", "email me at noon",
            "the dot product", "one dot two", "a dot of paint", "we dot the map",
            "read the sentence. Company policy applies", "the net is wide. Important news follows"
        ]
        for input in negatives {
            XCTAssertEqual(SpokenAddressNormalizer.apply(input), input, input)
        }
    }

    func testConnectiveSoIsNotNormalizedAsTheSoTopLevelDomain() {
        let input = "The backup is not complete, so don't delete the old copy."
        XCTAssertEqual(SpokenAddressNormalizer.apply(input), input)
        XCTAssertFalse(SpokenAddressNormalizer.changedAddress(
            answer: "The backup is not complete. So don't delete the old copy.", draft: input
        ))
    }

    func testPunctuatedRealDomainStillNormalizesAndRemainsProtected() {
        XCTAssertEqual(SpokenAddressNormalizer.apply("Visit tryhushy. com now"), "Visit tryhushy.com now")
        XCTAssertTrue(SpokenAddressNormalizer.changedAddress(
            answer: "Visit another.com now", draft: "Visit tryhushy.com now"
        ))
    }

    func testExplicitLiteralPronunciationFramingPreservesSpokenDomainsAcrossTLDs() {
        let cases = [
            "Just say Acme dot com out loud for the demo.",
            "Please pronounce Contoso dot co dot uk as words.",
            "Say Northwind dot io out loud.",
        ]
        for input in cases {
            XCTAssertEqual(SpokenAddressNormalizer.apply(input), input, input)
        }
    }

    func testQuotedAddressLikeTextRemainsLiteral() {
        let cases = [
            "Keep the phrase \"Acme dot com\" exactly as written.",
            "The transcript contains ‘Contoso dot co dot uk’ as a quoted example.",
            "Preserve `NORTHWIND.COM` verbatim.",
        ]
        for input in cases {
            XCTAssertEqual(SpokenAddressNormalizer.apply(input), input, input)
        }
    }

    func testLiteralAndGenuineSpokenURLInOneUtteranceUseOnlyLocalContext() {
        let input = "Say Acme dot com out loud, then visit Example dot Org."
        let expected = "Say Acme dot com out loud, then visit example.org."
        XCTAssertEqual(SpokenAddressNormalizer.apply(input), expected)
    }

    func testTypeAloneDoesNotSuppressSpokenDomainNormalization() {
        XCTAssertEqual(SpokenAddressNormalizer.apply("Type sample dot org into the browser."), "Type sample.org into the browser.")
    }

    func testWrittenURLAndSpokenEmailStillNormalize() {
        XCTAssertEqual(
            SpokenAddressNormalizer.apply("Visit HTTPS://EXAMPLE.COM/Docs now."),
            "Visit HTTPS://example.com/Docs now."
        )
        XCTAssertEqual(
            SpokenAddressNormalizer.apply("Email me at ada at example dot org."),
            "Email me at ada@example.org."
        )
    }

    func testCodePunctuationDoesNotJoinAdjacentFileNames() {
        let input = "we need index.ts, app.ts, and utils.ts"
        XCTAssertEqual(SpokenAddressNormalizer.apply(input, repairPunctuation: false), input)
        let options = CleanupOptions(level: .clean, isCodeContext: true)
        XCTAssertEqual(TextCleaner(options: options).clean("we need index dot ts, app dot ts, and utils dot ts").text, input)
        XCTAssertEqual(TextCleaner(options: options).clean("config dot json, app dot js, and package dot json").text,
                       "config.json, app.js, and package.json")
    }

    func testCodeStillNormalizesExplicitSpokenDomainsAndEmails() {
        XCTAssertEqual(SpokenAddressNormalizer.apply("visit example dot com", repairPunctuation: false), "visit example.com")
        XCTAssertEqual(SpokenAddressNormalizer.apply("send to alex at example dot org", repairPunctuation: false), "send to alex@example.org")
        XCTAssertEqual(SpokenAddressNormalizer.apply("example, com", repairPunctuation: false), "example, com")
        XCTAssertEqual(SpokenAddressNormalizer.apply("example, com"), "example.com")
    }

    func testModelCannotRewriteAddress() {
        XCTAssertTrue(SpokenAddressNormalizer.changedAddress(answer: "Visit other.com", draft: "Visit tryhushy.com"))
        XCTAssertFalse(SpokenAddressNormalizer.changedAddress(answer: "Visit tryhushy.com now", draft: "Visit tryhushy.com"))
    }

    func testAddressAlreadyWrittenDoesNotGainItsSpokenEndingAgain() {
        let cases: [(String, String)] = [
            ("open tryhushy.com dot com", "open tryhushy.com"),
            ("Open tryhushy.com dot com.", "Open tryhushy.com."),
            ("visit tryhushy.com dot com slash pricing", "visit tryhushy.com/pricing"),
            ("email ada at tryhushy.com dot com", "email ada@tryhushy.com"),
            ("go to blog.tryhushy.com dot com now", "go to blog.tryhushy.com now"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenAddressNormalizer.apply(input), expected, input)
            XCTAssertEqual(SpokenAddressNormalizer.apply(expected), expected, "idempotent: \(expected)")
        }
    }

    func testDictionaryTermThenSpokenEndingWritesTheEndingOnce() {
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "tryhushy.com", soundsLike: ["tryhushy", "try hushy"])])
        for input in ["open tryhushy dot com", "open try hushy dot com"] {
            let replaced = personalizer.apply(input).text
            XCTAssertEqual(SpokenAddressNormalizer.apply(replaced), "open tryhushy.com", input)
        }
    }
}
