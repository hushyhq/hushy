import Foundation
import Testing
@testable import MurmurCore

@Suite("Installed names preserve ordinary speech", .serialized)
struct InstalledNameOrdinaryWordsTests {
    private let ordinary = [
        "TextEdit", "Notes", "Mail", "Music", "Photos", "Messages", "Reminders", "Preview",
        "Pages", "Numbers", "Keynote", "Calendar", "Books", "News", "Stocks", "Weather",
        "Clock", "Maps", "Home", "Shortcuts", "TaskBoard", "DraftPad", "taskboard", "Task Board", "ToDo", "GoHome", "MyNotes",
    ]
    private let unusual = ["Figma", "Linear", "Supabase", "Obsidian"]
    private func settings(_ names: [String], frontmost: String? = nil) -> PipelineSettings {
        PipelineSettings(installedApps: names.map { InstalledAppInfo(bundleID: "test.\($0)", name: $0) },
                         frontmostBundleID: frontmost.map { "test.\($0)" })
    }

    @Test("single ordinary words and unlisted joined words never enter unconditional routes")
    func unconditionalRoutes() {
        let settings = settings(ordinary + unusual)
        let terms = settings.vocabulary.terms.filter(\.installedApp).map(\.text)
        let protection = DictationPipeline.cleanerInputs(settings).options.protectedTerms
        for name in ordinary {
            #expect(InstalledNamePolicy.isOrdinary(name), "\(name)")
            #expect(!terms.contains(name), "\(name)")
            #expect(!protection.contains(name), "\(name)")
        }
        for name in unusual {
            #expect(terms.contains(name), "\(name)")
            #expect(protection.contains(name), "\(name)")
        }
    }

    @Test("the existing boost guard already rejects a direct text-data replacement")
    func directBoost() {
        let context = VocabularyContext(terms: [VocabularyTerm(text: "TextEdit", source: .installedApp)])
        #expect(context.guarded(original: "export the text data", boosted: "export the TextEdit") == "export the text data")
    }

    @Test("a nonword in a boost region must not let an installed compound replace its ordinary neighbor")
    func nonwordBoostRegion() {
        let vocabulary = settings(["TextEdit"]).vocabulary
        let original = "export the text daeta"
        let replay = vocabulary.terms.contains { $0.text == "TextEdit" } ? "export the TextEdit" : original
        #expect(vocabulary.guarded(original: original, boosted: replay) == original)
    }

    @Test("draft alignment restores joined words and repeated installed-name substitutions")
    func draftAlignment() {
        let settings = settings(ordinary)
        for (draft, release) in [
            ("export the text data", "export the TextEdit"),
            ("text data and text data", "TextEdit and TextEdit"),
            ("save the text edit history", "save the TextEdit history"),
            ("update the task board", "update the TaskBoard"),
            ("review my notes", "review my Notes"),
        ] {
            let outcome = DraftCommonWordGuard.reconcile(draft: draft, release: release,
                vocabulary: settings.vocabulary, installedApps: settings.installedApps)
            // Case-only differences are harmless and remain the release pass's choice.
            #expect(outcome.text.lowercased() == draft.lowercased(), "\(draft)")
        }
    }

    @Test("explicit app naming and missing drafts keep the release reading")
    func realNames() {
        let settings = settings(ordinary + unusual)
        for (draft, release) in [
            ("open text edit", "open TextEdit"),
            ("launch text edit and wait", "launch TextEdit and wait"),
            ("open figma", "open Figma"),
        ] {
            #expect(DraftCommonWordGuard.reconcile(draft: draft, release: release,
                vocabulary: settings.vocabulary, installedApps: settings.installedApps).text == release)
        }
        #expect(DraftCommonWordGuard.reconcile(draft: nil, release: "TextEdit",
            installedApps: settings.installedApps).text == "TextEdit")
    }

    @Test("cleanup protection cannot lock in an ambiguous installed name")
    func cleanupProtection() {
        let options = DictationPipeline.cleanerInputs(settings(ordinary + unusual)).options
        #expect(ProtectedTermGuard.violation(answer: "export the text data", draft: "export the TextEdit",
                                            terms: options.protectedTerms) == nil)
        #expect(ProtectedTermGuard.violation(answer: "open the editor", draft: "open Figma",
                                            terms: options.protectedTerms) != nil)
    }

    @Test("the frontmost ordinary app cannot steal lowercase common words")
    func frontmostFixer() {
        let settings = settings(ordinary, frontmost: "Mail")
        for text in ["work with male", "the mail merge", "my notes", "page numbers", "text data", "text edit history"] {
            #expect(InstalledNameFixer.fix(text, settings: settings) == text)
        }
    }

    @Test("explicit Dictionary terms still win over automatic installed-name policy")
    func dictionaryOverride() {
        var settings = settings(["TextEdit"])
        settings.personalizer = Personalizer(dictionary: [DictionaryEntry(term: "TextEdit", soundsLike: ["text edit"])])
        #expect(settings.vocabulary.terms.contains { $0.text == "TextEdit" && !$0.installedApp })
        #expect(DraftCommonWordGuard.reconcile(draft: "save the text edit history", release: "save the TextEdit history",
            vocabulary: settings.vocabulary, installedApps: settings.installedApps).text == "save the TextEdit history")
    }
}
