import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("finetune groups: the app's own cuts and rules drafts, no model")
struct FinetuneGroupsTests {
    private let longText = """
        so the delivery is moving to thursday at three thirty and uh please tell marta that we are not changing \
        the budget. send me the new rota by friday. then check the van booking with dev because it was booked for \
        the wrong day. and after that look at the grocery card donation and tell ravi it was logged
        """

    @Test("a short text is one group, equal to the app's own cut")
    func shortTextIsOneGroup() {
        let row = FinetuneGroups.groupRow(["id": "a", "text": "we need twenty five chairs for the offsite"])
        let groups = row["groups"] as? [[String: Any]]
        #expect(groups?.count == 1 && row["groupCount"] as? Int == 1)
        #expect(groups?[0]["isTail"] as? Bool == true && groups?[0]["continuesSentence"] as? Bool == false)
        #expect(groups?[0]["draft"] as? String == "We need 25 chairs for the offsite.")
    }

    @Test("groups and drafts equal TextSegmentation and TextCleaner called directly")
    func matchesTheAppsCode() {
        let row = FinetuneGroups.groupRow(["id": "b", "text": longText])
        let expected = TextSegmentation.groups(longText)
        let cleaner = TextCleaner(options: FinetuneGroups.options(level: .clean, version: .v2))
        let groups = (row["groups"] as? [[String: Any]]) ?? []
        #expect(groups.count == expected.count && expected.count > 1)
        for (got, want) in zip(groups, expected) {
            #expect(got["text"] as? String == want.text)
            #expect(got["index"] as? Int == want.index && got["isTail"] as? Bool == want.isTail)
            #expect(got["continuesSentence"] as? Bool == want.continuesSentence)
            #expect(got["draft"] as? String == cleaner.clean(want.text).text)
        }
        #expect(row["wholeDraft"] as? String == cleaner.clean(longText).text)
    }

    @Test("a row without text reports the problem and the file round trip keeps the id")
    func missingTextAndRoundTrip() throws {
        #expect(FinetuneGroups.groupRow(["id": "c"])["error"] as? String == "missing text")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("in.jsonl").path
        let output = dir.appendingPathComponent("out.jsonl").path
        try FinetuneJSONL.write([["id": "r1", "spoken": "hello there"]], to: input)
        try FinetuneGroups.run(Arguments(["finetune", "groups", "--in", input, "--out", output][...]))
        let rows = try FinetuneJSONL.read(output)
        #expect(rows.count == 1 && rows[0]["id"] as? String == "r1" && rows[0]["groupCount"] as? Int == 1)
    }
}
