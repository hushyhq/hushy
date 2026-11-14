import Foundation
import Testing
@testable import MurmurCore

@Suite("Installed names in dictation", .serialized)
struct InstalledNameDictationTests {
    private struct FakeTranscriber: Transcriber {
        func transcribe(_ samples: [Float]) async throws -> String { "" }
    }
    private let apps = [
        InstalledAppInfo(bundleID: "example.assistant", name: "Claude", declaredCategory: nil),
        InstalledAppInfo(bundleID: "example.code", name: "Claude Code", declaredCategory: nil),
        InstalledAppInfo(bundleID: "example.editor", name: "Visual Studio Code", declaredCategory: nil),
        InstalledAppInfo(bundleID: "example.notes", name: "Notes", declaredCategory: nil),
        InstalledAppInfo(bundleID: "example.mail", name: "Mail", declaredCategory: nil),
        InstalledAppInfo(bundleID: "example.music", name: "Music", declaredCategory: nil),
        InstalledAppInfo(bundleID: "com.meta.endo", name: "Muse", declaredCategory: nil),
    ]

    @Test("installed display names join the existing vocabulary, with ordinary words excluded")
    func vocabulary() {
        let settings = PipelineSettings(installedApps: apps)
        let names = settings.vocabulary.terms.map(\.text)
        #expect(names.contains("Claude"))
        #expect(names.contains("Claude Code"))
        #expect(names.contains("Visual Studio Code"))
        #expect(!names.contains("Notes"))
        #expect(!names.contains("Mail"))
        #expect(!names.contains("Music"))
        #expect(!names.contains("Muse"))
        #expect(settings.vocabulary.guarded(original: "the cloud", boosted: "the Claude") == "the cloud")
        #expect(settings.vocabulary.guarded(original: "visual studio code", boosted: "Visual Studio Code") == "visual studio code")
    }

    @Test("an explicit name position can correct a phonetic common-word near miss")
    func namePositions() {
        let settings = PipelineSettings(installedApps: apps)
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: settings) == "ask Claude to summarize")
        #expect(InstalledNameFixer.fix("tell cloud about it", settings: settings) == "tell Claude about it")
        #expect(InstalledNameFixer.fix("cloud said yes", settings: settings) == "Claude said yes")
        #expect(InstalledNameFixer.fix("open cloud", settings: settings) == "open Claude")
        #expect(InstalledNameFixer.fix("launch cloud", settings: settings) == "launch Claude")
        #expect(InstalledNameFixer.fix("quit cloud", settings: settings) == "quit Claude")
        #expect(InstalledNameFixer.fix("use cloud app", settings: settings) == "use Claude app")
        #expect(InstalledNameFixer.fix("app cloud is running", settings: settings) == "app Claude is running")
        #expect(InstalledNameFixer.fix("cloud code is open", settings: settings) == "Claude Code is open")
        #expect(InstalledNameFixer.fix("launch cloud code", settings: settings) == "launch Claude Code")
        #expect(InstalledNameFixer.fix("cloud code", settings: settings) == "Claude Code")
        #expect(InstalledNameFixer.fix("cloud suggested a fix", settings: settings) == "Claude suggested a fix")
    }

    @Test("subject verbs of speech and thought use their inflected forms")
    func subjectInflections() {
        let settings = PipelineSettings(installedApps: apps)
        for verb in ["say", "says", "said", "saying", "write", "writes", "wrote", "writing",
                     "think", "thinks", "thought", "thinking", "suggest", "suggests", "suggested", "suggesting",
                     "answer", "answers", "answered", "answering", "reply", "replies", "replied", "replying",
                     "respond", "responds", "responded", "responding", "ask", "asks", "asked", "asking",
                     "tell", "tells", "told", "telling", "recommend", "recommends", "recommended", "recommending",
                     "explain", "explains", "explained", "explaining", "refuse", "refuses", "refused", "refusing"] {
            #expect(InstalledNameFixer.fix("cloud \(verb) calmly", settings: settings) == "Claude \(verb) calmly", "\(verb)")
        }
    }

    @Test("a participle before a plural noun remains a modifier")
    func participleModifiers() {
        let settings = PipelineSettings(installedApps: apps)
        for text in ["cloud based services", "cloud hosted tools", "cloud managed accounts",
                     "cloud covered hills", "cloud suggested changes", "cloud answered questions"] {
            #expect(InstalledNameFixer.fix(text, settings: settings) == text, "\(text)")
        }
    }

    @Test("addressing inflections can introduce a name")
    func addressingInflections() {
        let settings = PipelineSettings(installedApps: apps)
        for verb in ["ask", "asks", "asked", "asking", "tell", "tells", "told", "telling"] {
            #expect(InstalledNameFixer.fix("I \(verb) cloud to review it", settings: settings) == "I \(verb) Claude to review it", "\(verb)")
        }
    }

    @Test("a complete multiword name can appear inside a sentence")
    func embeddedCompleteName() {
        let settings = PipelineSettings(installedApps: apps)
        #expect(InstalledNameFixer.fix("I worked in cloud code and saved the file", settings: settings)
                == "I worked in Claude Code and saved the file")
        #expect(InstalledNameFixer.fix("I worked in the cloud code and saved the file", settings: settings)
                == "I worked in the cloud code and saved the file")
        #expect(InstalledNameFixer.fix("I read cloud code examples yesterday", settings: settings)
                == "I read cloud code examples yesterday")
        #expect(InstalledNameFixer.fix("I reviewed cloud code documentation yesterday", settings: settings)
                == "I reviewed cloud code documentation yesterday")
    }

    @Test("ordinary cloud speech and ordinary-word app names stay as heard")
    func ordinarySpeech() {
        let settings = PipelineSettings(installedApps: apps)
        for text in [
            "the cloud", "a cloud", "our cloud", "it's in the cloud", "cloud storage", "cloud provider",
            "cloud bill", "cloudy today", "a cloud moved over us", "clouds are coming",
            "in cloud storage", "with cloud cover", "using cloud services", "ask cloud storage to sync",
            "open music", "in notes", "tell mail about it",
            "everything is in cloud", "we archive data in cloud.", "ask cloud vendors for pricing",
            "tell cloud engineers about it", "migrating to cloud with backups", "open cloud dashboard",
            "in cloud, bills increase", "the transfer to cloud said it failed",
            "in cloud", "with cloud", "using cloud", "the cloud code is running",
            "the cloud app is running",
            "my cloud code is running", "green cloud code is running", "cloud code examples are useful",
            "cloud, said the reporter", "send to cloud said the log", "ask, cloud to summarize",
            "cloud is abundant", "cloud. code is running", "we switch to cloud", "switch to cloud",
        ] {
            #expect(InstalledNameFixer.fix(text, settings: settings) == text, "\(text)")
        }
    }

    @Test("unknown names and weak phonetic guesses do not rewrite")
    func requiresKnownName() {
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: PipelineSettings()) == "ask cloud to summarize")
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: PipelineSettings(installedApps: [
            InstalledAppInfo(bundleID: "example.weather", name: "Weather", declaredCategory: nil)
        ])) == "ask cloud to summarize")
    }

    @Test("an explicit common-word Dictionary alias retains its original replacement and protection")
    func dictionaryAlias() {
        let personalizer = Personalizer(dictionary: [DictionaryEntry(term: "Claude", soundsLike: ["cloud"])])
        let settings = PipelineSettings(personalizer: personalizer)
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: settings) == "ask cloud to summarize")
        #expect(personalizer.apply("the cloud").text == "the Claude")
        #expect(personalizer.heardAliases.contains { $0.heard == "cloud" && $0.term == "Claude" })
    }

    @Test("Dictionary alias wins through the complete cleanup pipeline")
    func dictionaryAliasPipeline() async {
        let settings = PipelineSettings(personalizer: Personalizer(dictionary: [
            DictionaryEntry(term: "Nimbus", soundsLike: ["cloud"])
        ]), installedApps: apps)
        let result = await DictationPipeline(transcriber: FakeTranscriber()).clean("ask cloud to summarize", settings: settings, strategy: .rules)
        #expect(result.raw == "ask cloud to summarize")
        #expect(result.text.contains("Nimbus"))
        #expect(!result.text.contains("Claude"))
    }

    @Test("case guard preserves whitespace when no installed name is involved")
    func guardedWhitespace() {
        let context = PipelineSettings(installedApps: apps).vocabulary
        let input = "  two  spaces\nand a line  "
        #expect(context.guarded(original: input, boosted: input) == input)
    }

    @Test("one flag disables both the installed boost and the name fixer")
    func featureFlag() async throws {
        let suiteName = "app.hushy.test.installed-names.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        let previous = FeatureFlags.source
        defer {
            FeatureFlags.source = previous
            suite.removePersistentDomain(forName: suiteName)
        }
        FeatureFlags.source = suite
        let settings = PipelineSettings(installedApps: apps)
        #expect(settings.vocabulary.terms.contains { $0.installedApp })
        suite.set(false, forKey: FeatureFlags.installedNamesKey)
        #expect(!settings.vocabulary.terms.contains { $0.installedApp })
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: settings) == "ask cloud to summarize")
        let result = await DictationPipeline(transcriber: FakeTranscriber())
            .clean("ask cloud to summarize", settings: settings, strategy: .rules)
        #expect(result.raw == "ask cloud to summarize")
    }

    @Test("the shared cap also limits fixer candidates and cleanup protection")
    func cappedNameCandidates() {
        let decoys = (0..<150).map { InstalledAppInfo(bundleID: "test.\($0)", name: "Widget\($0)") }
        let settings = PipelineSettings(installedApps: decoys + [apps[0]])
        #expect(settings.installedNameTerms().count == PipelineSettings.maxInstalledNameTerms)
        #expect(!settings.installedNameTerms().contains { $0.text == "Claude" })
        #expect(InstalledNameFixer.fix("ask cloud to summarize", settings: settings) == "ask cloud to summarize")
    }

    @Test("the fixer runs before As Spoken and code cleanup")
    func cleanupLevels() async {
        let pipeline = DictationPipeline(transcriber: FakeTranscriber())
        for options in [CleanupOptions(level: .verbatim), CleanupOptions(level: .clean, isCodeContext: true)] {
            let settings = PipelineSettings(cleanupOptions: options, installedApps: apps)
            let result = await pipeline.clean("ask cloud to summarize", settings: settings, strategy: .rules)
            #expect(result.raw == "ask Claude to summarize")
        }
    }

    @Test("installed names have a cap after all user and context terms")
    func cappedVocabulary() {
        let apps = (0..<200).map { InstalledAppInfo(bundleID: "test.\($0)", name: "AppName\($0)") }
        let dictionary = (0..<160).map { DictionaryEntry(term: "UserName\($0)") }
        let settings = PipelineSettings(personalizer: Personalizer(dictionary: dictionary),
                                        contextTerms: ["ContextName"], installedApps: apps)
        let terms = settings.vocabulary.terms.map(\.text)
        #expect(terms.prefix(160).elementsEqual(dictionary.map(\.term)))
        #expect(terms[160] == "ContextName")
        #expect(terms.filter { $0.hasPrefix("AppName") }.count == 150)
    }

    @Test("only installed app terms have common-word casing restored")
    func dictionaryCasing() {
        let user = VocabularyContext.from(dictionary: [DictionaryEntry(term: "Rose")])
        // An ordinary-word Dictionary term keeps the recogniser's case in the boost; the Dictionary pass after cleanup
        // capitalizes it where the sentence names the person or product (`OrdinaryTermCase`).
        #expect(user.guarded(original: "rose", boosted: "Rose") == "rose")
        let rose = Personalizer(dictionary: [DictionaryEntry(term: "Rose")])
        #expect(rose.apply("ask rose about it").text == "ask Rose about it")
        #expect(rose.apply("a rose by any other name").text == "a rose by any other name")
        // Ordinary two-word names no longer enter the vocabulary at all.
        #expect(PipelineSettings(installedApps: [InstalledAppInfo(bundleID: "test.editor", name: "Rose Editor")])
            .vocabulary.terms.allSatisfy { $0.text != "Rose Editor" })
        let installed = VocabularyContext(terms: [VocabularyTerm(text: "Rose Editor", source: .installedApp)])
        #expect(installed.guarded(original: "rose editor", boosted: "Rose Editor") == "rose editor")
    }

    @Test("a weak preposition cue is allowed only in that frontmost app")
    func frontmostApp() {
        let ordinary = PipelineSettings(installedApps: apps)
        let frontmost = PipelineSettings(installedApps: apps, frontmostBundleID: "example.assistant")
        #expect(InstalledNameFixer.fix("working in cloud", settings: ordinary) == "working in cloud")
        #expect(InstalledNameFixer.fix("working in cloud", settings: frontmost) == "working in Claude")
        #expect(InstalledNameFixer.fix("working with cloud", settings: frontmost) == "working with Claude")
        #expect(InstalledNameFixer.fix("drafting using cloud", settings: frontmost) == "drafting using Claude")
    }

    @Test("an ordinary app name is repaired only by the frontmost preposition cue")
    func frontmostOrdinaryName() {
        let muse = PipelineSettings(installedApps: apps, frontmostBundleID: "com.meta.endo")
        let other = PipelineSettings(installedApps: apps, frontmostBundleID: "example.assistant")
        #expect(InstalledNameFixer.fix("I'm talking in Mews, and it is slow", settings: muse)
                == "I'm talking in Muse, and it is slow")
        #expect(InstalledNameFixer.fix("I need to muse on it", settings: muse) == "I need to muse on it")
        #expect(InstalledNameFixer.fix("I'm talking in Mews", settings: other) == "I'm talking in Mews")
        #expect(InstalledNameFixer.fix("in the Muse app", settings: other) == "in the Muse app")
        for text in ["ask Mews to summarize", "open Mews", "Mews said yes", "use Mews app"] {
            #expect(InstalledNameFixer.fix(text, settings: muse) == text, "\(text)")
        }
    }

    @Test("an exact ordinary word stays as heard even in its frontmost app")
    func exactOrdinaryName() {
        let notes = PipelineSettings(installedApps: apps, frontmostBundleID: "example.notes")
        #expect(InstalledNameFixer.fix("write it in notes, and", settings: notes) == "write it in notes, and")
        #expect(InstalledNameFixer.fix("I need notes for it", settings: notes) == "I need notes for it")
    }

    @Test("the rules pass receives the corrected name before cleanup")
    func pipelineRulesPass() async {
        struct FakeTranscriber: Transcriber {
            func transcribe(_ samples: [Float]) async throws -> String { "ask cloud to summarize" }
        }
        let pipeline = DictationPipeline(transcriber: FakeTranscriber())
        let result = await pipeline.clean("ask cloud to summarize", settings: PipelineSettings(installedApps: apps), strategy: .rules)
        #expect(result.raw == "ask Claude to summarize")
        #expect(result.text.contains("Claude"))
    }
}
