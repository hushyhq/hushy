import Foundation
import Testing
@testable import MurmurCore

/// What a log line or metric can carry about a file search: a code, nothing else.
@Suite("FileFindOutcomeCode")
struct FileFindOutcomeCodeTests {
    @Test("the codes are exactly the content-free list")
    func codes() {
        #expect(Set(FileFindOutcomeCode.allCases.map(\.rawValue)) == ["found-one", "found-several", "none", "unavailable", "cancelled"])
    }

    @Test("no code carries a payload", arguments: FileFindOutcomeCode.allCases)
    func noPayload(code: FileFindOutcomeCode) {
        #expect(Mirror(reflecting: code).children.isEmpty)
        #expect(code.logLine == "file search: \(code.rawValue)")
    }

    @Test("a log line for any outcome has no name, path or term in it")
    func logLineIsFixedText() {
        let file = FileFixtures.file("Documents/Secret plan acme.pdf", FileFixtures.now, kinds: FileFixtures.pdf)
        let outcomes: [FileFindOutcome] = [
            .foundOne(file, matchedBy: .name), .foundSeveral([file], matchedBy: .content), .none,
            .unavailable(.slow), .cancelled,
        ]
        for outcome in outcomes {
            let line = outcome.code.logLine
            #expect(!line.contains("Secret"))
            #expect(!line.contains("acme"))
            #expect(!line.contains("/"))
            #expect(["file search: found-one", "file search: found-several", "file search: none",
                     "file search: unavailable", "file search: cancelled"].contains(line))
        }
    }

    @Test("the unavailable reasons carry no text either")
    func reasons() {
        for reason in FileSearchUnavailable.allCases { #expect(Mirror(reflecting: reason).children.isEmpty) }
    }
}
