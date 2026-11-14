import Testing
@testable import MurmurCore

@Suite("FileVocabulary")
struct FileSynonymTests {
    @Test("synonyms come from a small closed table")
    func synonyms() {
        #expect(Set(FileVocabulary.variants(of: "resume")) == ["resume", "cv", "curriculum vitae"])
        #expect(Set(FileVocabulary.variants(of: "cv")) == ["cv", "resume", "curriculum vitae"])
        #expect(Set(FileVocabulary.variants(of: "deck")) == ["deck", "slides", "presentation"])
        #expect(Set(FileVocabulary.variants(of: "sheet")) == ["sheet", "spreadsheet"])
    }

    @Test("a word outside the table has only itself and its singular")
    func noInvention() {
        #expect(FileVocabulary.variants(of: "invoice") == ["invoice"])
        #expect(Set(FileVocabulary.variants(of: "invoices")) == ["invoices", "invoice"])
        #expect(FileVocabulary.variants(of: "boss") == ["boss"])
    }

    @Test("a CV named file is found by saying resume, and the reverse")
    func nameMatching() {
        let groups = FileVocabulary.variants(of: "resume")
        #expect(FileRanker.nameMatch("Dana CV.pdf", groups: [groups]).coverage == 1)
        #expect(FileRanker.nameMatch("Quarterly report.pdf", groups: [groups]).coverage == 0)
    }
}
