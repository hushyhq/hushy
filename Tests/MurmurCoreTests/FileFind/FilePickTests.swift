import Foundation
import Testing
@testable import MurmurCore

@Suite("FilePick")
struct FilePickTests {
    typealias F = FileFixtures

    private let rows: [FilePickRow] = [
        FilePickRow(name: "Resume.pdf", kinds: F.pdf, modified: F.date(2026, 9, 20), folder: F.home.path + "/Documents/Jobs"),
        FilePickRow(name: "Resume 2024.docx", kinds: F.docx, modified: F.date(2024, 3, 4), folder: F.home.path + "/Downloads"),
        FilePickRow(name: "Resume old.pdf", kinds: F.pdf, modified: F.date(2023, 3, 9), folder: F.home.path + "/Desktop"),
    ]

    private func pick(_ utterance: String, _ rows: [FilePickRow]? = nil) -> FilePick.Result {
        FilePick.resolve(utterance, rows: rows ?? self.rows, now: F.now, calendar: F.calendar)
    }

    @Test("ordinals", arguments: [
        ("the first one", 0), ("the second one", 1), ("number three", 2), ("the third", 2), ("the last one", 2), ("second", 1),
    ])
    func ordinals(utterance: String, index: Int) {
        #expect(pick(utterance) == .picked(index: index, open: false))
    }

    @Test("by kind, date, place, age and name")
    func descriptors() {
        #expect(pick("the docx") == .picked(index: 1, open: false))
        #expect(pick("the one from 2024") == .picked(index: 1, open: false))
        #expect(pick("the one in downloads") == .picked(index: 1, open: false))
        #expect(pick("the newest") == .picked(index: 0, open: false))
        #expect(pick("the oldest one") == .picked(index: 2, open: false))
        #expect(pick("the one called old") == .picked(index: 2, open: false))
        #expect(pick("the first pdf") == .picked(index: 0, open: false))
        #expect(pick("the second pdf") == .picked(index: 2, open: false))
    }

    @Test("open is carried")
    func opens() {
        #expect(pick("open the second one") == .picked(index: 1, open: true))
    }

    @Test("more than one fit, or none, is said back, never guessed")
    func unclear() {
        #expect(pick("the pdf") == .several)
        #expect(pick("the one from march") == .several)
        #expect(pick("the spreadsheet") == .noMatch)
        #expect(pick("the sixth one") == .noMatch)
    }

    @Test("other speech is not a pick", arguments: [
        "what does it say about pricing", "add coffee to groceries", "summarize that", "remind me to call dana",
        "find my invoice", "thanks",
    ])
    func notAPick(utterance: String) {
        #expect(pick(utterance) == .notAPick)
    }

    @Test("a single file: open it, show it")
    func single() {
        let one = [rows[0]]
        #expect(pick("open it", one) == .picked(index: 0, open: true))
        #expect(pick("show it in finder", one) == .picked(index: 0, open: false))
    }
}
