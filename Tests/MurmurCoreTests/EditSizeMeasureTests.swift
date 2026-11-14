import Foundation
import Testing
@testable import MurmurCore

/// How many words the person changed after a paste: counted from the dictation lined up with the field, then
/// put in a bucket. Only the bucket leaves; these tests use invented sentences.
@Suite("Edit size after paste", .timeLimit(.minutes(1)))
struct EditSizeMeasureTests {
    let text = "Please send me the report on Monday morning before the meeting starts."

    @Test("one word replaced is one word changed")
    func oneWord() {
        let field = text.replacingOccurrences(of: "Monday", with: "Tuesday")
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: field) == 1)
        #expect(EditSizeMeasure.size(inserted: text, fieldValue: field) == .words1to2)
    }

    @Test("a word added, a word removed, and a run replaced")
    func addRemoveReplace() {
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: text.replacingOccurrences(of: "Monday morning", with: "Monday early morning")) == 1)
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: text.replacingOccurrences(of: "the report ", with: "report ")) == 1)
        // Three words become two: the longer side counts.
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: text.replacingOccurrences(of: "on Monday morning", with: "tomorrow early")) == 3)
    }

    @Test("a change to capitals or punctuation alone counts as one word, so an edit is never zero")
    func surfaceOnly() {
        let field = text.replacingOccurrences(of: "starts.", with: "starts!")
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: field) == 1)
        #expect(EditSizeMeasure.size(inserted: text, fieldValue: field) == .words1to2)
        let bare = EditSizeMeasure.size(inserted: text, fieldValue: text.replacingOccurrences(of: "Please", with: "please"))
        #expect(bare == .words1to2)
    }

    @Test("buckets follow the number of words: 3 to 10, then more")
    func buckets() {
        let few = text.replacingOccurrences(of: "report on Monday morning", with: "slides this afternoon sharp")
        #expect(EditSizeMeasure.size(inserted: text, fieldValue: few) == .words3to10)
        // Forty distinct words, twelve in a row replaced: more than ten changed, and most of the text still there.
        let words = (1...40).map { "word\($0)" }
        let original = words.joined(separator: " ")
        var edited = words
        edited.replaceSubrange(14..<26, with: (1...12).map { "other\($0)" })
        #expect(EditSizeMeasure.wordsChanged(inserted: original, fieldValue: edited.joined(separator: " ")) == 12)
        #expect(EditSizeMeasure.size(inserted: original, fieldValue: edited.joined(separator: " ")) == .wordsMore)
        edited = words
        edited.replaceSubrange(14..<24, with: (1...10).map { "other\($0)" })
        #expect(EditSizeMeasure.size(inserted: original, fieldValue: edited.joined(separator: " ")) == .words3to10)
    }

    @Test("the dictation is found inside a longer field, with the person's own text around it")
    func insideALongerField() {
        let field = "Hi Sam,\n\n" + text.replacingOccurrences(of: "Monday", with: "Friday") + "\n\nThanks a lot,\nAda\n\nOn Tuesday, Sam wrote:\n> see you then"
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: field) == 1)
    }

    @Test("a dictation that cannot be found in the field is counted in the largest bucket")
    func notFound() {
        let rewritten = "Could you possibly forward the quarterly numbers tomorrow, thanks"
        #expect(EditSizeMeasure.wordsChanged(inserted: text, fieldValue: rewritten) == nil)
        #expect(EditSizeMeasure.size(inserted: text, fieldValue: rewritten) == .wordsMore)
    }

    @Test("a field that is far too long is not searched at all, and counts as the largest bucket")
    func hugeField() {
        let huge = String(repeating: "lorem ipsum dolor sit amet ", count: 200_000)
        #expect(EditSizeMeasure.size(inserted: text, fieldValue: huge) == .wordsMore)
    }
}
