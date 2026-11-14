import Foundation
import Testing
@testable import MurmurCore

private struct StubModel: LanguageModel {
    let json: String
    var available = true
    var identifier: String { "stub" }
    var availability: LanguageModelAvailability { available ? .available : .unavailable(reason: "off") }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        json
    }
}

@Suite("FileQueryExtractor")
struct FileQueryExtractorTests {
    typealias F = FileFixtures

    private func extract(_ json: String, _ utterance: String = "where is my passport scan", available: Bool = true) async -> FileRequest? {
        await FileQueryExtractor(model: StubModel(json: json, available: available)).extract(utterance, now: F.now, calendar: F.calendar)
    }

    private func output(
        file: Bool = true, words: String = "[\"passport\", \"scan\"]", kind: String = "any", time: String = "",
        location: String = "none"
    ) -> String {
        #"{"isFileRequest":\#(file),"nameWords":\#(words),"kind":"\#(kind)","time":"\#(time)","location":"\#(location)"}"#
    }

    @Test("a model answer becomes the typed query")
    func fills() async {
        let request = await extract(output(kind: "pdf", time: "march", location: "downloads"))
        #expect(request == F.request(["passport", "scan"], kind: .pdf, time: .month(3), location: .downloads))
    }

    @Test("not a file request is nil")
    func notAFile() async {
        #expect(await extract(output(file: false)) == nil)
    }

    @Test("no model is nil, never a guess")
    func noModel() async {
        #expect(await extract(output(), available: false) == nil)
    }

    @Test("garbage output is nil")
    func garbage() async {
        #expect(await extract("not json") == nil)
    }

    @Test("a word the person did not say is dropped")
    func invented() async {
        let request = await extract(output(words: "[\"passport\", \"visa\", \"../../etc\"]"))
        #expect(request == F.request(["passport"]))
        #expect(await extract(output(words: "[\"visa\"]")) == nil)
    }

    @Test("a path from the model is cut to the plain words the person said")
    func pathsRefused() async {
        let request = await extract(output(words: "[\"/Users/x/passport.pdf\"]"), "where is my passport")
        #expect(request?.query.terms == ["passport"])
    }

    @Test("a request the model had to guess never opens, even if the person said open")
    func neverOpens() async {
        #expect(await extract(output(), "where is my passport scan")?.action == .reveal)
        #expect(await extract(output(), "open my passport scan")?.action == .reveal)
    }
}
