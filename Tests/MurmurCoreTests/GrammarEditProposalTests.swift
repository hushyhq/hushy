import Foundation
import Synchronization
import Testing
@testable import MurmurCore

@Suite("Source-anchored grammar edit proposals")
struct GrammarEditProposalTests {
    @Test("Apple-compatible schema declares ordered required fields")
    func schemaShape() throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(GrammarEditProposal.generationSchema.json.utf8)) as? [String: Any])
        #expect(root["x-order"] as? [String] == ["edits"])
        let properties = try #require(root["properties"] as? [String: Any])
        let edits = try #require(properties["edits"] as? [String: Any])
        let item = try #require(edits["items"] as? [String: Any])
        #expect(item["x-order"] as? [String] == ["source", "replacement"])
        #expect(item["required"] as? [String] == ["source", "replacement"])
    }

    @Test("empty edits preserve all original bytes, including Unicode whitespace")
    func emptyEditsAreExactNoOp() throws {
        let source = "  Café\u{00A0}—\tline\n\u{2003}end  "
        let result = try #require(try GrammarEditApplicator.apply(.init(edits: []), to: source).get())
        #expect(Array(result.text.utf8) == Array(source.utf8))
        #expect(result.edits.isEmpty)
        #expect(result.isByteIdenticalNoOp)
    }

    @Test("exact unique anchors apply in descending order and preserve unrelated Unicode")
    func multipleEdits() throws {
        let source = "Zoë says: the team have access; cafés are open."
        let proposal = GrammarEditProposal(edits: [
            .init(source: "team have", replacement: "team has"),
            .init(source: "cafés are", replacement: "cafés remain"),
        ])
        let result = try #require(try GrammarEditApplicator.apply(proposal, to: source).get())
        #expect(result.text == "Zoë says: the team has access; cafés remain open.")
        #expect(!result.isByteIdenticalNoOp)
        #expect(result.edits.map(\.sourceByteCount) == [9, 10])
        #expect(result.edits.allSatisfy { !$0.wholeSentenceReplacement })
    }

    @Test("missing, empty, and ambiguous anchors fail closed")
    func badAnchors() {
        #expect(GrammarEditApplicator.apply(.init(edits: [.init(source: "absent", replacement: "x")]), to: "hello")
            == .failure(.missingAnchor(edit: 0)))
        #expect(GrammarEditApplicator.apply(.init(edits: [.init(source: "", replacement: "x")]), to: "hello")
            == .failure(.emptySourceAnchor(edit: 0)))
        #expect(GrammarEditApplicator.apply(.init(edits: [.init(source: "ha", replacement: "ho")]), to: "ha ha")
            == .failure(.ambiguousAnchor(edit: 0, occurrences: 2)))
        #expect(GrammarEditApplicator.apply(.init(edits: [.init(source: "ana", replacement: "x")]), to: "banana")
            == .failure(.ambiguousAnchor(edit: 0, occurrences: 2)))
    }

    @Test("overlapping resolved edits reject the complete proposal")
    func overlappingEdits() {
        let proposal = GrammarEditProposal(edits: [
            .init(source: "abc", replacement: "x"),
            .init(source: "cde", replacement: "y"),
        ])
        #expect(GrammarEditApplicator.apply(proposal, to: "abcde") == .failure(.overlappingEdits(first: 0, second: 1)))
    }

    @Test("protected UTF-16 spans reject intersecting edits and invalid ranges")
    func protectedRanges() {
        let source = "say café today"
        let protected = (source as NSString).range(of: "café")
        let edit = GrammarEditProposal(edits: [.init(source: "café", replacement: "coffee")])
        #expect(GrammarEditApplicator.apply(edit, to: source, protectedSpans: [protected])
            == .failure(.protectedSpanOverlap(edit: 0, span: 0)))
        #expect(GrammarEditApplicator.apply(.init(edits: []), to: source, protectedSpans: [NSRange(location: 99, length: 2)])
            == .failure(.invalidProtectedSpan(span: 0)))
    }

    @Test("diagnostics count UTF-8 bytes and identify sentence-sized replacements")
    func diagnostics() throws {
        let source = "Café shines brightly."
        let proposal = GrammarEditProposal(edits: [.init(source: source, replacement: "Café glows brightly.")])
        let result = try #require(try GrammarEditApplicator.apply(proposal, to: source).get())
        let edit = try #require(result.edits.first)
        #expect(edit.sourceRangeUTF8 == 0..<source.utf8.count)
        #expect(edit.sourceByteCount == source.utf8.count)
        #expect(edit.replacementByteCount == "Café glows brightly.".utf8.count)
        #expect(edit.wholeSentenceReplacement)
    }

    @Test("generator uses the typed schema interface and keeps versioned prompt formats distinct")
    func generatorCall() async throws {
        let expectedJSON = #"{"edits":[{"source":"team have","replacement":"team has"}]}"#
        let model = ProposalModel(json: expectedJSON)
        let result = await GrammarEditProposalGenerator.generate(
            model: model, preparedDraft: "the team have access", format: .compactV5, budget: .seconds(3))
        let proposal = try #require(try result.get())
        #expect(proposal.edits == [.init(source: "team have", replacement: "team has")])
        let call = try #require(model.calls.first)
        #expect(call.schema == GrammarEditProposal.generationSchema)
        #expect(call.options == .greedyTextTransform)
        #expect(call.instructions.contains(GrammarEditProposalGenerator.compactInstructions))
        #expect(call.prompt.contains("the team have access"))
        #expect(call.prompt.contains("language=unknown; mode=prose context"))
        #expect(GrammarEditProposalGenerator.promptVersion == "clean-general-source-edits-v1")
        #expect(GrammarEditProposalGenerator.schemaVersion == "grammar-edit-proposal-schema-v1")
        #expect(GrammarEditProposalGenerator.productionInstructions != GrammarEditProposalGenerator.compactInstructions)
    }

    @Test("proposal application is not an implicit semantic approval")
    func structuralResultNamesOnlyStructuralFacts() throws {
        let proposal = GrammarEditProposal(edits: [.init(source: "Ada", replacement: "Ravi")])
        let result = try #require(try GrammarEditApplicator.apply(proposal, to: "Ada sent the note.").get())
        #expect(result.text == "Ravi sent the note.")
        #expect(!result.isByteIdenticalNoOp)
    }

    @Test("whole-text and edit formats share one grammar policy and context payload")
    func wholeTextComparisonArm() async throws {
        let context = GrammarProposalContext(isCodeContext: false, detectedLanguage: "en", protectedTerms: ["Hushy"])
        let editModel = ProposalModel(json: #"{"edits":[]}"#)
        let wholeTextModel = ProposalModel(json: #"{"text":"The report is ready."}"#)
        _ = await GrammarEditProposalGenerator.generate(
            model: editModel, preparedDraft: "the report is ready", format: .compactV5,
            context: context, budget: .seconds(3))
        let whole = await GrammarEditProposalGenerator.generateWholeText(
            model: wholeTextModel, preparedDraft: "the report is ready", context: context, budget: .seconds(3))
        #expect(try whole.get().text == "The report is ready.")
        let editCall = try #require(editModel.calls.first)
        let textCall = try #require(wholeTextModel.calls.first)
        #expect(textCall.options == .greedy)
        #expect(!textCall.options.textTransform)
        let trainingRequest = try GrammarEditProposalGenerator.wholeTextRequest(preparedDraft: "the report is ready", context: context)
        #expect(trainingRequest.instructions == textCall.instructions)
        #expect(trainingRequest.prompt == textCall.prompt)
        #expect(editCall.prompt == textCall.prompt.replacingOccurrences(of: "Return corrected draft:", with: "Propose edits:"))
        #expect(editCall.prompt.contains("language=en; mode=prose context"))
        #expect(editCall.instructions.contains(GrammarEditProposalGenerator.minimalGrammarPolicy))
        #expect(textCall.instructions.contains(GrammarEditProposalGenerator.minimalGrammarPolicy))
        #expect(editCall.instructions.contains("\"detectedLanguage\":\"en\""))
        #expect(textCall.instructions.contains("\"detectedLanguage\":\"en\""))
        #expect(editCall.instructions.contains("\"protectedTerms\":[\"Hushy\"]"))
        #expect(textCall.instructions.contains("\"protectedTerms\":[\"Hushy\"]"))
        #expect(editCall.prompt.contains("Hushy"))
        #expect(textCall.prompt.contains("Hushy"))
        #expect(editCall.schema.name == GrammarEditProposal.generationSchema.name)
        #expect(textCall.schema == WholeGrammarProposal.generationSchema)
        #expect(GrammarEditProposalGenerator.wholeTextPromptVersion == "clean-general-whole-text-v1")
    }

    @Test("code and non-English context explicitly exclude grammar changes")
    func excludedContexts() async {
        let code = GrammarProposalContext(isCodeContext: true, detectedLanguage: "en")
        let editModel = ProposalModel(json: #"{"edits":[]}"#)
        let textModel = ProposalModel(json: #"{"text":"let value=  1;"}"#)
        _ = await GrammarEditProposalGenerator.generate(
            model: editModel, preparedDraft: "let value=  1;", format: .compactV5,
            context: code, budget: .seconds(3))
        _ = await GrammarEditProposalGenerator.generateWholeText(
            model: textModel, preparedDraft: "let value=  1;", context: code, budget: .seconds(3))
        #expect(editModel.calls.first?.prompt.contains("excluded from grammar repair") == true)
        #expect(textModel.calls.first?.prompt.contains("excluded from grammar repair") == true)

        let spanish = ProposalModel(json: #"{"edits":[]}"#)
        _ = await GrammarEditProposalGenerator.generate(
            model: spanish, preparedDraft: "el informe está listo",
            context: .init(detectedLanguage: "es"), budget: .seconds(3))
        #expect(spanish.calls.first?.prompt.contains("language=es; mode=prose context") == true)
        #expect(spanish.calls.first?.prompt.contains("excluded from grammar repair") == true)
    }

    @Test("diagnostics report hard vetoes without treating nil as semantic acceptance")
    func hardVetoDiagnostics() {
        let code = GrammarProposalContext(isCodeContext: true, detectedLanguage: "en")
        #expect(GrammarProposalDiagnostics.hardViolation(
            raw: "let x=1;", draft: "let x=1;", candidate: "let x=1;", context: code) == nil)
        #expect(GrammarProposalDiagnostics.hardViolation(
            raw: "let x=1;", draft: "let x=1;", candidate: "let x = 1;", context: code) != nil)

        let spanish = GrammarProposalContext(detectedLanguage: "es")
        #expect(GrammarProposalDiagnostics.hardViolation(
            raw: "el informe", draft: "el informe", candidate: "el informe está listo", context: spanish) != nil)

        let protected = GrammarProposalContext(protectedTerms: ["Hushy"])
        #expect(GrammarProposalDiagnostics.hardViolation(
            raw: "Hushy needs help", draft: "Hushy needs help", candidate: "Hush needs help", context: protected) != nil)

        // The absence of a hard veto does not mean the change is semantically approved.
        #expect(GrammarProposalDiagnostics.hardViolation(
            raw: "a report arrived", draft: "a report arrived", candidate: "the report arrived",
            context: .init()) == nil)
    }
}

private final class ProposalModel: LanguageModel, @unchecked Sendable {
    struct Call: Sendable {
        let schema: GenerationSchemaSpec
        let instructions: String
        let prompt: String
        let options: LanguageModelOptions
    }

    private let json: String
    private let state = Mutex<[Call]>([])

    init(json: String) { self.json = json }

    var calls: [Call] { state.withLock { $0 } }
    var identifier: String { "grammar-edit-proposal-test" }
    var availability: LanguageModelAvailability { .available }
    var contextTokens: Int { LanguageModelContext.defaultTokens }
    func supportsLanguage(_ languageCode: String) -> Bool { languageCode == "en" }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        state.withLock { $0.append(Call(schema: schema, instructions: instructions, prompt: prompt, options: options)) }
        return json
    }
}
