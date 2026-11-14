import Foundation
import Testing
@testable import MurmurCore

/// A dictation with list dashes, em dashes or bullets is still found in the field when the editor shows the dashes as
/// bullet points or drops them (a rich message box such as Claude's). A token with no letter or digit has an empty
/// key and never matches, so it must not count as a word that did not survive. Every sentence is invented.
@Suite("Locating a dictation with punctuation-only tokens")
struct PunctuationTokenLocationTests {
    private let list = "- do it\n- go\n- run\n- hop"

    @Test("the dashes shown as bullets, or dropped, still locate the dictation and make no edit")
    func bulletsAreNotEdits() throws {
        for field in ["• do it\n• go\n• run\n• hop", "do it\ngo\nrun\nhop", "- do it\n- go\n- run\n- hop and more", "Steps:\n\u{2022} do it\n\u{2022} go\n\u{2022} run\n\u{2022} hop\nThanks"] {
            let located = try #require(CorrectionAlignment.locate(inserted: list, in: field), "\(field)")
            #expect(located.edits.isEmpty, "\(field)")
        }
    }

    @Test("one fixed word in such a list is the only edit")
    func oneFixInAList() throws {
        let inserted = "Next - check the Veloria log - restart the worker - report back to the team - done"
        let field = "Next - check the Valeria log - restart the worker - report back to the team - done"
        let located = try #require(CorrectionAlignment.locate(inserted: inserted, in: field))
        #expect(located.edits == [WordEdit(before: ["Veloria"], after: ["Valeria"])])
        let bullets = "Next • check the Valeria log • restart the worker • report back to the team • done"
        let bulleted = try #require(CorrectionAlignment.locate(inserted: inserted, in: bullets))
        #expect(bulleted.edits == [WordEdit(before: ["Veloria"], after: ["Valeria"])])
        // Mostly dashes: 4 words and 4 dashes.
        let sparse = try #require(CorrectionAlignment.locate(inserted: "- go - run - hop - sit", in: "- go - run - jump - sit"))
        #expect(sparse.edits == [WordEdit(before: ["hop"], after: ["jump"])])
    }

    @Test("other text in its place is still not the dictation")
    func otherTextStillNotLocated() {
        #expect(CorrectionAlignment.locate(inserted: list, in: "the crates are packed and the cart leaves at dawn") == nil)
        #expect(CorrectionAlignment.locate(inserted: list, in: "- the cart leaves\n- at dawn\n- with the crates") == nil)
        #expect(CorrectionAlignment.locate(inserted: "- - - -", in: "- - - -") == nil)
    }

    @Test("punctuation-only tokens that differ are not a style change")
    func dashesAreNotSurfaceChanges() throws {
        let located = try #require(CorrectionAlignment.locate(inserted: "go - run - hop - sit - now", in: "go — run — hop — sit — now"))
        #expect(located.edits.isEmpty)
        #expect(located.surfaceChanges.isEmpty)
    }
}
