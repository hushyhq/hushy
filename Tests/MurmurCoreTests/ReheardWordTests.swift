import Foundation
import Testing
@testable import MurmurCore

/// A content word the model corrected to the word that was meant counts as kept, not dropped, when at every place it
/// stood the answer has a plausible re-hearing of it. One occurrence and every occurrence are judged the same way;
/// a word that is simply gone, swapped for an unrelated word, or swapped only in some places is still a loss.
@Suite("Re-heard word is kept", .timeLimit(.minutes(2)), .serialized)
struct ReheardWordTests {
    private let draft = "Please set a remainder for Monday morning and I want the remainder to repeat every week and send the remainder to Kenji before lunch."

    private func objection(_ answer: String, draft: String? = nil, low: Set<String>? = nil) -> String? {
        let said = draft ?? self.draft
        return DisfluencyOnlyGuard.violation(
            answer: answer, raw: said.lowercased(), draft: said, grammarRepair: true, lowConfidenceWords: low)
    }

    @Test("a word corrected at all three places it was heard is not dropped, with or without recogniser confidence")
    func correctedEverywhere() {
        let answer = draft.replacingOccurrences(of: "remainder", with: "reminder")
        #expect(objection(answer) == nil, "\(String(describing: objection(answer)))")
        #expect(objection(answer, low: ["remainder"]) == nil, "\(String(describing: objection(answer, low: ["remainder"])))")
    }

    @Test("a word heard once and corrected is judged the same way")
    func correctedOnce() {
        let said = "Please set a remainder for Monday morning and send the notes to Kenji before lunch today."
        let answer = said.replacingOccurrences(of: "remainder", with: "reminder")
        #expect(objection(answer, draft: said) == nil, "\(String(describing: objection(answer, draft: said)))")
    }

    @Test("the near-spelling relation is shape only: inflections and a few edits yes, extensions and unrelated words no")
    func nearSpelling() {
        #expect(WordRelation.isNearSpelling("remainder", "reminder"))
        #expect(WordRelation.isNearSpelling("shiped", "shipped"))
        #expect(WordRelation.isNearSpelling("report", "reports"))
        #expect(!WordRelation.isNearSpelling("remainder", "calendar"))
        #expect(!WordRelation.isNearSpelling("priya", "priyanka"))
        #expect(!WordRelation.isNearSpelling("book", "notebook"))
        #expect(!WordRelation.isNearSpelling("", "word"))
    }

    @Test("a word that is simply gone everywhere is still a loss")
    func goneEverywhere() {
        let answer = "Please set one for Monday morning and I want it to repeat every week and send it to Kenji before lunch."
        #expect(objection(answer) != nil)
    }

    @Test("a word swapped for an unrelated one everywhere is still a loss")
    func unrelatedEverywhere() {
        let answer = draft.replacingOccurrences(of: "remainder", with: "calendar")
        #expect(objection(answer) != nil)
    }

    @Test("a word corrected in two places and swapped for an unrelated one in the third is still a loss")
    func corrected​InSomePlaces() {
        let answer = "Please set a reminder for Monday morning and I want the reminder to repeat every week and send the calendar to Kenji before lunch."
        #expect(objection(answer) != nil)
    }

    @Test("a word corrected in two places and deleted in the third is still a loss")
    func deletedInOnePlace() {
        let answer = "Please set a reminder for Monday morning and I want the reminder to repeat every week and send it to Kenji before lunch."
        #expect(objection(answer) != nil)
    }
}
