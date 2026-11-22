import CryptoKit
import Foundation
import MurmurCore

/// `murmur-eval meeting --answers <dir>`: keeps every answer of the shared model on disk, keyed by what was asked, and
/// gives it back when the same call comes again. A first run fills the folder from the model; a later run of a
/// grounding or selection change replays the same answers in seconds, so the change is measured on the model's own
/// output and nothing else moves. A replay is one draw: greedy calls on the 4B do not repeat run to run (two fresh
/// ami-test runs of one binary, 2026-11-14, gave the same answer to 1 of the 40 calls both made), so measure the spread
/// with fresh folders before reading a small difference.
final class AnswerCache: LanguageModel {
    private let base: any LanguageModel
    private let folder: URL

    init(base: any LanguageModel, folder: URL) throws {
        self.base = base
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var identifier: String { base.identifier }
    var availability: LanguageModelAvailability { base.availability }
    var contextTokens: Int { base.contextTokens }
    func supportsLanguage(_ languageCode: String) -> Bool { base.supportsLanguage(languageCode) }
    func prewarm(instructions: String) { base.prewarm(instructions: instructions) }
    func prefixCache(instructions: String) async { await base.prefixCache(instructions: instructions) }
    func warmForDictation(instructions: String) async { await base.warmForDictation(instructions: instructions) }
    func yieldToForeground() async { await base.yieldToForeground() }

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let file = folder.appendingPathComponent(Self.key(instructions, prompt, schema, options) + ".txt")
        if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        let answer = try await base.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
        try answer.write(to: file, atomically: true, encoding: .utf8)
        return answer
    }

    static func key(_ instructions: String, _ prompt: String, _ schema: GenerationSchemaSpec, _ options: LanguageModelOptions) -> String {
        let asked = [instructions, prompt, schema.name, schema.json, options.sampling == .greedy ? "greedy" : "sampled"]
        return SHA256.hash(data: Data(asked.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
