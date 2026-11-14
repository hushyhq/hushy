import XCTest
@testable import MurmurCore

/// The step the pipeline runs before the model and on its answer: spoken addresses, and code-like names the person has
/// on screen or in the Dictionary, in the form they are typed.
final class WrittenFormsTests: XCTestCase {
    private func settings(screen: [String] = [], dictionary: [String] = [], level: CleanupLevel = .clean) -> PipelineSettings {
        PipelineSettings(
            cleanupOptions: CleanupOptions(level: level),
            personalizer: Personalizer(dictionary: dictionary.map { DictionaryEntry(term: $0) }),
            contextTerms: screen)
    }

    func testScreenAndDictionaryNamesAreWrittenAsShown() {
        let screen = settings(screen: ["TRY-95", "rl-v9"])
        XCTAssertEqual(DictationPipeline.writtenForms("The bug is tracked in TRY95.", settings: screen), "The bug is tracked in TRY-95.")
        XCTAssertEqual(DictationPipeline.writtenForms("rerun r l v nine tonight", settings: screen), "rerun rl-v9 tonight")
        let own = settings(dictionary: ["TRY-107"])
        XCTAssertEqual(DictationPipeline.writtenForms("it is try one hundred seven", settings: own), "it is TRY-107")
    }

    func testEmailsAreJoinedWithNoContextAndNamesAreNotGuessed() {
        let bare = settings()
        XCTAssertEqual(DictationPipeline.writtenForms("Send the invite to John at gmail.com.", settings: bare), "Send the invite to john@gmail.com.")
        XCTAssertEqual(DictationPipeline.writtenForms("The bug is tracked in TRY95.", settings: bare), "The bug is tracked in TRY95.")
    }

    func testOrdinarySpeechIsNotJoined() {
        let all = settings(screen: ["TRY-95"], dictionary: ["rl-v9"])
        for sentence in ["meet me at the station dot", "I'm at home", "we try 95 times", "Let's meet next week instead.",
                         "She took the initiative on the hiring plan."] {
            XCTAssertEqual(DictationPipeline.writtenForms(sentence, settings: all), sentence, sentence)
        }
    }

    func testAsSpokenKeepsTheWords() {
        let verbatim = settings(screen: ["TRY-95"], level: .verbatim)
        XCTAssertEqual(DictationPipeline.writtenForms("john at gmail dot com TRY95", settings: verbatim), "john at gmail dot com TRY95")
    }
}
