import Foundation
import Testing
@testable import MurmurCore

/// Task 143: a code editor or terminal gets the same grammar repair as every other app, and what is code in what
/// was said (a command, a flag, a path, an identifier, a number, a quoted string) comes back exactly as dictated.
@Suite("Code context grammar repair", .timeLimit(.minutes(1)))
struct CodeContextGrammarTests {
    private let terminal = "com.apple.Terminal"

    private func settings(_ tones: ToneSettings, mode: Mode? = nil, bundleID: String = "com.apple.Terminal") -> PipelineSettings {
        let resolved = mode ?? Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        return PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: resolved,
            category: AppCategory.classify(bundleID: bundleID, windowTitle: nil), bundleID: bundleID, windowTitle: nil)
    }

    // MARK: The plan

    @Test("a code app runs at Polished with code protections on, and no tone or layout, whatever the tone setting")
    func codeAppIsPolishedWithProtections() {
        for choice in [ToneChoice.refined, .casual, .professional] {
            var tones = ToneSettings.standard.settingTone(.casual, for: .other)
            tones.choice = choice
            // The plan itself, not only the mode the helper resolves: this fails if the code kind goes back to Cleaned up.
            #expect(tones.plan(for: .code).level == .polished, "\(choice)")
            for id in [terminal, "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.googlecode.iterm2"] {
                #expect(tones.plan(for: .code, bundleID: id).level == .polished, "\(id) \(choice)")
                let result = settings(tones, bundleID: id)
                #expect(result.cleanupOptions.level == .polished, "\(id) \(choice)")
                #expect(result.cleanupOptions.isCodeContext, "\(id) \(choice)")
                #expect(result.tone == nil && result.style == nil, "\(id) \(choice)")
            }
        }
    }

    @Test("As spoken stays as spoken in a code app, with the code protections still on")
    func asSpokenIsUnchanged() {
        var tones = ToneSettings.standard
        tones.choice = .asSpoken
        let result = settings(tones)
        #expect(result.cleanupOptions.level == .verbatim)
        #expect(result.cleanupOptions.isCodeContext)
        #expect(result.tone == nil)
    }

    @Test("a mode the person picked for a code app keeps its own level, and a prose app's own tone still wins")
    func explicitChoicesWin() {
        let tones = ToneSettings.standard
        let cleaned = Mode(name: "Mine", icon: "star", cleanupLevel: .clean, appBundleIDs: [terminal])
        #expect(settings(tones, mode: cleaned).cleanupOptions.level == .clean)
        let own = ToneSettings.standard.settingApp(.tone(.casual), bundleIDs: ["com.example.notes"])
        #expect(own.plan(for: .other, bundleID: "com.example.notes").tone == .casual)
        #expect(own.plan(for: .code, bundleID: terminal).tone == nil)
    }

    @Test("other languages stay at Cleaned up in a code app, as they do with a tone elsewhere")
    func otherLanguagesStayClean() {
        var result = settings(ToneSettings.standard)
        #expect(result.resolvedForLanguage().cleanupOptions.level == .polished)
        result.cleanupOptions.detectedLanguage = "de"
        #expect(result.resolvedForLanguage().cleanupOptions.level == .clean)
        #expect(result.resolvedForLanguage().cleanupOptions.isCodeContext)
    }

    // MARK: What the model may not change

    @Test("a repaired sentence passes; an identifier, a flag, a path, a number or a quoted string that changes does not")
    func guardReadsCodeByShape() {
        let draft = "can you run git commit -m \"fix the retry bug\" in src/utils/parse_input.py with getUserById at 2.3.1"
        #expect(CodeContextGuard.violation(answer: draft, draft: draft) == nil)
        let repaired = "Can you run git commit -m \"fix the retry bug\" in src/utils/parse_input.py with getUserById at 2.3.1"
        #expect(CodeContextGuard.violation(answer: repaired, draft: draft) == nil)
        for broken in [
            "Can you run git commit -m \"fixes the retry bug\" in src/utils/parse_input.py with getUserById at 2.3.1",
            "Can you run git commit -m \"fix the retry bug\" in src/utils/parse_input.py with getUserByID at 2.3.1",
            "Can you run git commit -m \"fix the retry bug\" in src/utils/parse input.py with getUserById at 2.3.1",
            "Can you run git commit m \"fix the retry bug\" in src/utils/parse_input.py with getUserById at 2.3.1",
            "Can you run git commit -m \"fix the retry bug\" in src/utils/parse_input.py with getUserById at 2.3",
        ] {
            #expect(CodeContextGuard.violation(answer: broken, draft: draft) != nil, "\(broken)")
        }
    }

    @Test("a quoted string is kept as a whole even when no token inside it is code-shaped")
    func quotedStringsStayWhole() {
        let draft = "can you print \"hello there world\" for me"
        // Every token is the same as in the draft; only the words inside the quotes differ.
        #expect(CodeContextGuard.violation(answer: "Can you print \"hello then world\" for me?", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "Can you print \"hello there world\" for me?", draft: draft) == nil)
        let backticks = "please run `cargo build release` again"
        #expect(CodeContextGuard.violation(answer: "Please run `cargo build --release` again.", draft: backticks) != nil)
    }

    @Test("a command made of plain words is read by shape and kept exactly: no capital, no final stop, no reordering")
    func plainCommandsAreKept() {
        for command in ["git push origin main", "npm install typescript", "make build", "docker compose up", "kubectl get pods", "cd src", "ls"] {
            #expect(CodeContextGuard.readsAsCommand(command), "\(command)")
            #expect(CodeContextGuard.violation(answer: command.prefix(1).uppercased() + command.dropFirst() + ".", draft: command) != nil, "\(command)")
            #expect(CodeContextGuard.violation(answer: command + ".", draft: command) != nil, "\(command)")
            #expect(CodeContextGuard.violation(answer: command, draft: command) == nil, "\(command)")
        }
        #expect(CodeContextGuard.violation(answer: "git origin push main", draft: "git push origin main") != nil)
        for sentence in ["can you check the logs", "the tests is failing", "I don't know why", "why does the build fail", "fix the bug"] {
            #expect(!CodeContextGuard.readsAsCommand(sentence), "\(sentence)")
        }
        // A quoted string and a flag do not make a sentence of a command.
        #expect(CodeContextGuard.readsAsCommand("git commit -m \"fix the bug in the parser\""))
    }

    @Test("a comment is prose after its marker: the marker stays, the sentence is repaired")
    func commentsAreRepaired() {
        for comment in ["// this function don't handle the empty list", "# we retry three times because the server fails", "/// todo remove this once the migration is done"] {
            #expect(!CodeContextGuard.readsAsCommand(comment), "\(comment)")
        }
        #expect(CodeContextGuard.violation(answer: "// This function doesn't handle the empty list.", draft: "// this function don't handle the empty list") == nil)
        #expect(CodeContextGuard.violation(answer: "This function doesn't handle the empty list.", draft: "// this function don't handle the empty list") != nil)
        #expect(CodeContextGuard.readsAsCommand("x = 1 // this is fine"))
    }

    @Test("the model may not bring in a code-shaped token the draft did not say, or move one the draft held")
    func inventedAndMovedTokens() {
        let draft = "please call the parse header function when the input is empty"
        #expect(CodeContextGuard.violation(answer: "Please call the parse header function when the input is empty.", draft: draft) == nil)
        #expect(CodeContextGuard.violation(answer: "Please call the parseBody function when the input is empty.", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "Please call the parseHeaders function when the input is empty.", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "Please call the parse_header_v2 function when the input is empty.", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "Please retry 5 times.", draft: "please retry five times") != nil)
        // A plain word the model capitalises as an acronym is allowed.
        #expect(CodeContextGuard.violation(answer: "The CSV is empty.", draft: "the csv is empty") == nil)
        #expect(CodeContextGuard.violation(answer: "The CSV is empty.", draft: "the file is empty") != nil)
    }

    // Accuracy eval, 2026-11-11: 128 of 171 Terminal fallbacks were these repairs refused (code-002, code-004, code-011).
    @Test("words said in a prose line may be written as the identifier they name, as in any other app")
    func spokenWordsWrittenAsCode() {
        #expect(CodeContextGuard.violation(answer: "Move the fetch into a useEffect hook.", draft: "move the fetch into a use effect hook") == nil)
        #expect(CodeContextGuard.violation(answer: "Please call the parseHeader function.", draft: "please call the parse header function") == nil)
        #expect(CodeContextGuard.violation(answer: "Please use the built-in parser.", draft: "please use the built in parser") == nil)
        #expect(CodeContextGuard.violation(answer: "Set NODE_ENV to production.", draft: "set node underscore env to production") == nil)
        #expect(CodeContextGuard.violation(answer: "Can you rerun the rl-v9 eval?", draft: "can you rerun the rl v9 eval") == nil)
        // A draft identifier written as typed: a hyphen between letters and digits, spelled capitals, a lower-case run in capitals.
        #expect(CodeContextGuard.violation(answer: "The bug is tracked in TRY-95.", draft: "the bug is tracked in TRY95") == nil)
        #expect(CodeContextGuard.violation(answer: "Set NODE_ENV to production.", draft: "set node_env to production") == nil)
        #expect(CodeContextGuard.violation(answer: "Can you update the README.md file?", draft: "can you update the readme.md file") == nil)
        #expect(CodeContextGuard.violation(answer: "We are on v30 now.", draft: "we are on V30 now") == nil)
        #expect(CodeContextGuard.violation(answer: "Set the minimum to iOS 18.", draft: "set the minimum to IOS 18") == nil)
        #expect(CodeContextGuard.violation(answer: "Run pnpm install before you build.", draft: "run PNPM install before you build") == nil)
        #expect(CodeContextGuard.violation(answer: "The endpoint is /api/v2/users.", draft: "the endpoint is slash API slash V2 slash users") == nil)
        // Accuracy eval code-042 in Terminal: the rules joined the path but not its spoken opening slash.
        #expect(CodeContextGuard.violation(answer: "The endpoint is /api/v2/users.", draft: "the endpoint is slash API/V2/users") == nil)
    }

    @Test("writing out what was said never changes a digit, a separator between digits, a flag's case or a mixed-case name")
    func writtenFormsKeepCode() {
        #expect(CodeContextGuard.violation(answer: "The bug is tracked in TRY-96.", draft: "the bug is tracked in TRY95") != nil)
        #expect(CodeContextGuard.violation(answer: "The bug is tracked in TRY95.", draft: "the bug is tracked in TRY-95") != nil)
        #expect(CodeContextGuard.violation(answer: "It reads 3,5 as text.", draft: "it reads 3.5 as text") != nil)
        #expect(CodeContextGuard.violation(answer: "We ship 2.31 today.", draft: "we ship 2.3.1 today") != nil)
        #expect(CodeContextGuard.violation(answer: "We ship 2.3.1 today.", draft: "we ship 2 3 1 today") != nil)
        #expect(CodeContextGuard.violation(answer: "Can you run it with --Force on main?", draft: "can you run it with --force on main") != nil)
        #expect(CodeContextGuard.violation(answer: "Call getUserByID for the user.", draft: "call getUserById for the user") != nil)
        #expect(CodeContextGuard.violation(answer: "Open src/utils/parse-input.py for me.", draft: "open src/utils/parse_input.py for me") != nil)
        #expect(CodeContextGuard.violation(answer: "Open src/App.ts for me.", draft: "open src/app.ts for me") != nil)
        // code-context-dev B21: a path keeps its case.
        #expect(CodeContextGuard.violation(answer: "The endpoint is API/v2/users.", draft: "the endpoint is api/v2/users") != nil)
        // A code-shaped draft token inside a joined run must come through as it was.
        #expect(CodeContextGuard.violation(answer: "Can you rerun the rl-V9 eval?", draft: "can you rerun the rl v9 eval") != nil)
        // Order still holds when the newcomer is a written form.
        #expect(CodeContextGuard.violation(answer: "Open b.py and then useEffect.", draft: "open use effect and then b.py") != nil)
    }

    @Test("a sentence with a hyphenated word, a decimal and a product name is still repaired around those tokens")
    func repairsAroundCodeShapedTokens() {
        let draft = "the tests is failing because the built-in parser reads 3.5 as text in GitHub"
        #expect(CodeContextGuard.violation(answer: "The tests are failing because the built-in parser reads 3.5 as text in GitHub.", draft: draft) == nil)
        #expect(CodeContextGuard.violation(answer: "The tests are failing because the built in parser reads 3.5 as text in GitHub.", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "The tests are failing because the built-in parser reads 3,5 as text in Github.", draft: draft) != nil)
    }

    @Test("a protected token stays in its own line, and the answer keeps the draft's line breaks")
    func tokensAreBoundToTheirLine() {
        let draft = "can you open a.py for me\nthen you can open b.py"
        #expect(CodeContextGuard.violation(answer: "Can you open a.py for me?\nThen you can open b.py.", draft: draft) == nil)
        #expect(CodeContextGuard.violation(answer: "Can you open b.py for me?\nThen you can open a.py.", draft: draft) != nil)
        #expect(CodeContextGuard.violation(answer: "Can you open a.py for me, then you can open b.py.", draft: draft) != nil)
    }

    @Test("a draft without code is prose: any grammar repair passes, and an apostrophe in a word is not code")
    func proseIsFree() {
        let draft = "the tests is failing and i dont know why so can you check the the fixtures"
        let repaired = "The tests are failing and I don't know why. Can you check the fixtures?"
        #expect(CodeContextGuard.violation(answer: repaired, draft: draft) == nil)
        #expect(!CodeContextGuard.isCodeShaped("don't"))
        #expect(CodeContextGuard.isCodeShaped("'quoted'"))
        #expect(CodeContextGuard.isCodeShaped("camelCase"))
        #expect(CodeContextGuard.isCodeShaped("--force"))
        #expect(!CodeContextGuard.isCodeShaped("Hello"))
    }

    @Test("a statement stays whole: its plain words are code too")
    func statementsStayWhole() {
        #expect(CodeContextGuard.isStatement("let value = 7;"))
        #expect(CodeContextGuard.isStatement("}") && CodeContextGuard.isStatement("const f = (n) => n * 2"))
        #expect(!CodeContextGuard.isStatement("can you check the logs --force"))
        #expect(!CodeContextGuard.isStatement("rename the function to parseHeader and update the callers."))
        #expect(CodeContextGuard.violation(answer: "Let the value = 7;", draft: "let value = 7;") != nil)
        // A second line of prose beside a statement is still free.
        #expect(CodeContextGuard.violation(answer: "let value = 7;\nThe tests are failing.", draft: "let value = 7;\nthe tests is failing") == nil)
    }

    @Test("order matters: a code token moved past another is a change")
    func orderIsKept() {
        #expect(CodeContextGuard.violation(answer: "run b.py then a.py", draft: "run a.py then b.py") != nil)
    }

    // MARK: Through the cleaner

    @Test("the model repairs the prose around a command and gets the command back exactly; a changed flag is put back alone")
    func cleanerKeepsTheCommand() async {
        let draftText = "um can you run git commit -m fix_retry --force on the the main branch"
        let model = RewriteModel { _ in "Can you run git commit -m fix_retry --Force on the main branch?" }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            draftText, options: CleanupOptions(level: .polished, isCodeContext: true), strategy: .model, incremental: false)
        #expect(output.text.contains("--force"))
        #expect(!output.text.contains("--Force"))
        #expect(output.text.contains("git commit -m fix_retry"))
        #expect(!output.text.contains("the the"))
        #expect(output.text.hasPrefix("Can you run"))
    }

    @Test("an answer that rewrites only prose is used as it is")
    func cleanerUsesAProseFix() async {
        let model = RewriteModel { _ in "The tests are failing on the login page." }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "the tests is failing on the login page", options: CleanupOptions(level: .polished, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(output.usedModel)
        #expect(output.text == "The tests are failing on the login page.")
    }

    @Test("Cleaned up keeps a code app's text as the rules wrote it: the model's answer counts only when it changes nothing")
    func cleanedUpStaysRulesOnly() async {
        let model = RewriteModel { _ in "The tests are failing on the login page." }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "the tests is failing on the login page", options: CleanupOptions(level: .clean, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(!output.usedModel)
        #expect(output.text == "the tests is failing on the login page")
        #expect(CodeContextGuard.violation(answer: "The tests", draft: "the tests", repairsGrammar: false) != nil)
        #expect(CodeContextGuard.violation(answer: "the tests", draft: "the tests", repairsGrammar: false) == nil)
        // An answer that changes nothing still counts, as it did before: a refusal of every answer would fail here.
        let same = RewriteModel { $0 }
        let unchanged = await SmartCleaner(model: same, health: ModelHealth()).clean(
            "the tests is failing on the login page", options: CleanupOptions(level: .clean, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(unchanged.usedModel)
    }

    @Test("a plain-word command reaches the cleaner and comes back with no capital and no final stop")
    func cleanerKeepsAPlainCommand() async {
        let model = RewriteModel { _ in "Git push origin main." }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "git push origin main", options: CleanupOptions(level: .polished, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(!output.usedModel)
        #expect(output.text == "git push origin main")
    }

    @Test("a code-shaped token the model invents is put back and the rest of the repair stays")
    func cleanerPutsBackAnInventedToken() async {
        // parse_headers was not said ("parse header"): a written form must say exactly the words said.
        let model = RewriteModel { _ in "Please call the parse_headers function when the input is empty." }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "please call the parse header function when the input is empty",
            options: CleanupOptions(level: .polished, isCodeContext: true), strategy: .model, incremental: false)
        #expect(output.text.contains("parse header"))
        #expect(!output.text.contains("parse_headers"))
        #expect(output.text.hasPrefix("Please call"))
    }

    @Test("a model that rewrites a statement is still refused")
    func cleanerRefusesARewrittenStatement() async {
        let model = RewriteModel { _ in "Let the value equal seven." }
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "let value = 7;", options: CleanupOptions(level: .polished, isCodeContext: true),
            strategy: .model, incremental: false)
        #expect(!output.usedModel)
        #expect(output.text == "let value = 7;")
    }
}

private struct RewriteModel: LanguageModel {
    let answer: @Sendable (String) -> String
    init(_ answer: @escaping @Sendable (String) -> String) { self.answer = answer }
    var identifier: String { "synthetic-code-rewrite-143" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": answer(draft)]), as: UTF8.self)
    }
}
