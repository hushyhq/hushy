import Foundation
import FoundationModels
import Testing
@testable import HushyModelsApple
@testable import MurmurCore

/// Each MurmurCore `GenerationSchemaSpec`, decoded by the Apple adapter, must encode to exactly
/// the `GenerationSchema` its old `@Generable` type produced — the schema is part of the prompt,
/// so this is what makes the seam "no behaviour change" for the model.
@Suite("Apple adapter schema parity")
struct SchemaParityTests {
    @available(macOS 26.0, *)
    static func encoded(_ schema: GenerationSchema) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(schema)
    }

    @available(macOS 26.0, *)
    static func expectParity(_ spec: GenerationSchemaSpec, _ legacy: GenerationSchema) throws {
        let decoded = try AppleFoundationModel.decode(spec)
        let got = try String(decoding: encoded(decoded), as: UTF8.self)
        let want = try String(decoding: encoded(legacy), as: UTF8.self)
        #expect(got == want, "\(spec.name) schema drifted from its @Generable original")
        #expect(spec.json.trimmingCharacters(in: .whitespacesAndNewlines) == want, "\(spec.name) spec text is not canonical")
    }

    @Test("Cleaned") func cleaned() throws {
        guard #available(macOS 26.0, *) else { return }
        try Self.expectParity(SmartCleaner.Cleaned.generationSchema, Legacy.Cleaned.generationSchema)
    }

    @Test("RerankAnswer") func rerank() throws {
        guard #available(macOS 26.0, *) else { return }
        try Self.expectParity(SmartCleaner.RerankAnswer.generationSchema, Legacy.RerankAnswer.generationSchema)
    }

    /// The meeting-digest schemas have no `@Generable` original: they must decode, and encode back
    /// to their own text (so the model sees exactly the schema MurmurCore wrote).
    @Test("meeting-digest schemas decode and round-trip")
    func meetingDigestSchemas() throws {
        guard #available(macOS 26.0, *) else { return }
        for spec in [MeetingPartNotes.generationSchema, MeetingDigest.generationSchema, MeetingMerge.generationSchema] {
            let decoded = try AppleFoundationModel.decode(spec)
            let got = try String(decoding: Self.encoded(decoded), as: UTF8.self)
            #expect(got == spec.json.trimmingCharacters(in: .whitespacesAndNewlines), "\(spec.name) does not round-trip")
        }
    }

    @Test("Transformed") func transformed() throws {
        guard #available(macOS 26.0, *) else { return }
        try Self.expectParity(ModeExecutor.Transformed.generationSchema, Legacy.Transformed.generationSchema)
    }

    @Test("GeneratedActionEnvelope") func actionEnvelope() throws {
        guard #available(macOS 26.0, *) else { return }
        try Self.expectParity(GeneratedActionEnvelope.generationSchema, Legacy.GeneratedActionEnvelope.generationSchema)
    }

    @Test("the old types' JSON decodes into MurmurCore's plain mirrors")
    func legacyJSONDecodes() throws {
        guard #available(macOS 26.0, *) else { return }
        let action = Legacy.GeneratedAction(
            kind: .createEvent, title: "Dentist", when: "tomorrow at 3", durationMinutes: 45,
            listOrCalendarName: "Home", location: "", shortcutInput: "")
        let envelope = Legacy.GeneratedActionEnvelope(speech: .askingYou, actions: [action])
        let decoded = try JSONDecoder().decode(
            GeneratedActionEnvelope.self, from: Data(envelope.generatedContent.jsonString.utf8))
        #expect(decoded.speech == .askingYou)
        #expect(decoded.actions.first?.kind == .createEvent)
        #expect(decoded.actions.first?.durationMinutes == 45)
        #expect(decoded.actions.first?.listOrCalendarName == "Home")

        let rerank = Legacy.RerankAnswer(keeps: .both, droppedInformation: true)
        let decodedRerank = try JSONDecoder().decode(
            SmartCleaner.RerankAnswer.self, from: Data(rerank.generatedContent.jsonString.utf8))
        #expect(decodedRerank.keeps == .both)
        #expect(decodedRerank.droppedInformation)
    }

    @Test("greedy maps to greedy sampling at temperature 0; systemDefault to the framework default")
    func optionsMapping() {
        guard #available(macOS 26.0, *) else { return }
        #expect(AppleFoundationModel.generationOptions(.greedy) == GenerationOptions(sampling: .greedy, temperature: 0))
        #expect(AppleFoundationModel.generationOptions(.systemDefault) == GenerationOptions())
    }
}
