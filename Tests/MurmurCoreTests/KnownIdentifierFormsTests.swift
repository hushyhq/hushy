import XCTest
@testable import MurmurCore

final class KnownIdentifierFormsTests: XCTestCase {
    private let terms = ["rl-v9", "TRY-95", "TRY-107", "useEffect", "S3", "Llama 3.1 70B", "bdf01317"]

    private func apply(_ text: String, terms: [String]? = nil) -> String {
        KnownIdentifierForms.apply(text, terms: terms ?? self.terms)
    }

    func testRecogniserFormsBecomeTheKnownForm() {
        XCTAssertEqual(apply("The bug is tracked in TRY95."), "The bug is tracked in TRY-95.")
        XCTAssertEqual(apply("The bug is tracked in try 95."), "The bug is tracked in TRY-95.")
        XCTAssertEqual(apply("Can you rerun the RLv9 eval tonight?"), "Can you rerun the rl-v9 eval tonight?")
        XCTAssertEqual(apply("the \"TRY107\" ticket"), "the \"TRY-107\" ticket")
    }

    func testAGluedEnglishWordIsSplitOff() {
        XCTAssertEqual(apply("Can you rerun the RLv9Eval tonight?"), "Can you rerun the rl-v9 eval tonight?")
    }

    func testSpokenWordsBecomeTheKnownForm() {
        XCTAssertEqual(apply("it is try ninety five"), "it is TRY-95")
        XCTAssertEqual(apply("rerun r l v nine tonight"), "rerun rl-v9 tonight")
        XCTAssertEqual(apply("see try one oh seven, then"), "see TRY-107, then")
        XCTAssertEqual(apply("upload it to s three"), "upload it to S3")
    }

    func testANameNobodyShowedIsNotGuessed() {
        XCTAssertEqual(apply("The bug is tracked in TRY95.", terms: []), "The bug is tracked in TRY95.")
        XCTAssertEqual(apply("the SHA256 of the file", terms: terms), "the SHA256 of the file")
        XCTAssertEqual(apply("hash UTF8 and H264", terms: terms), "hash UTF8 and H264")
        XCTAssertEqual(apply("TRY96 is next", terms: terms), "TRY96 is next")
    }

    func testOrdinarySpeechAboutNumbersIsLeftAlone() {
        let sentences = [
            "I will try 95 times",
            "we try 95 percent of the cases",
            "try 9 and then 5",
            "it takes about try ninety five minutes",
            "the model is rl v9 percent faster",
        ]
        for sentence in sentences { XCTAssertEqual(apply(sentence), sentence, sentence) }
    }

    func testAKnownFormIsKept() {
        XCTAssertEqual(apply("see TRY-95 and rl-v9."), "see TRY-95 and rl-v9.")
        let once = apply("see try 95")
        XCTAssertEqual(apply(once), once)
    }

    func testAnAmbiguousKeyIsNotUsed() {
        XCTAssertEqual(apply("see try 95", terms: ["TRY-95", "try_95"]), "see try 95")
    }

    func testARejectedPairStaysAsHeard() {
        let kept = KnownIdentifierForms.apply("see TRY95", terms: terms) { heard, written in heard == "TRY95" && written == "TRY-95" }
        XCTAssertEqual(kept, "see TRY95")
    }
}
