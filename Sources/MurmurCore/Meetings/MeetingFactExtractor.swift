import Foundation
import os

/// A meeting's decisions, action items, open questions and changes, each tied to a quote and a moment
/// (meetings schema freeze section 5). The transcript is cut into chunks of about 1,800 words at turn boundaries
/// (`MeetingExtractPrompt.chunks`), each chunk is one model call with the extract prompt, and every record is
/// grounded against its chunk (`MeetingFactGrounder`). On the shared local 4B with the Run A adapter installed the
/// engine turns the adapter on for these calls only (schema `MeetingRecords`).
///
/// Dictation first: each call waits for quiet (`LanguageModel.yieldToForeground`), and a call a dictation cut short
/// (`ForegroundPreempted`) is asked again once the dictation is over; it is not a failure.
public struct MeetingFactExtractor: Sendable {
    public struct Report: Sendable, Equatable {
        public var chunks = 0
        public var calls = 0
        public var failedChunks = 0
        public var preempted = 0
        public var records = 0
        public var verified = 0
        public var unsupported = 0
        /// Actions whose model owner was not a speaker or a name said there: stored as a claim, shown unassigned.
        public var ownersDropped = 0
        public var milliseconds = 0.0
        public init() {}
    }

    /// The extractor name stored on each fact: the Run A adapter on the 4B, else the model that answered.
    public static func extractorName(for model: any LanguageModel) -> String {
        model.identifier.contains(MeetingExtractAdapter.name) ? MeetingExtractAdapter.extractorName : "\(model.identifier)/extract-p1"
    }

    public let model: any LanguageModel
    /// Answer tokens per call, as the Python eval decoded (`MAX_NEW_TOKENS`).
    public var maxPreemptionsPerChunk = 40
    private static let log = Logger(subsystem: "app.hushy", category: "notes")

    public init(model: any LanguageModel) {
        self.model = model
    }

    /// The facts for one note's transcript, in transcript order. `kind` is how the meeting is described in the
    /// prompt ("meeting", "call").
    public func extract(
        _ transcript: NoteTranscript, noteId: Int64, title: String, kind: String
    ) async -> (facts: [MeetingFact], report: Report) {
        var report = Report()
        let began = ContinuousClock.now
        defer { _ = began }
        let lines = MeetingExtractPrompt.lines(of: transcript)
        guard model.isAvailable, !lines.isEmpty else { return ([], report) }
        let speakers = Self.speakers(of: transcript)
        let size = MeetingExtractPrompt.Size.forContext(tokens: model.contextTokens)
        let chunks = MeetingExtractPrompt.chunks(lines, size: size)
        report.chunks = chunks.count
        let extractor = Self.extractorName(for: model)
        let schema = usesNullableSchema ? MeetingExtractPrompt.schema : MeetingExtractPrompt.plainSchema
        let labels = speakers.map(\.label).sorted()
        var facts: [MeetingFact] = []
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { break }
            let prompt = MeetingExtractPrompt.userTurn(
                title: title, kind: kind, speakers: labels, chunk: "\(index + 1) of \(chunks.count)",
                transcript: chunk.map(\.rendered).joined(separator: "\n"))
            guard let answer = await call(prompt, schema: schema, report: &report) else {
                report.failedChunks += 1
                continue
            }
            report.records += answer.records.count
            let grounded = MeetingFactGrounder.facts(answer.records, chunk: chunk, speakers: speakers, noteId: noteId, extractor: extractor)
            facts += grounded
        }
        let ordered = MeetingFactGrounder.ordered(facts)
        report.verified = ordered.filter { $0.grounding == .verified }.count
        report.unsupported = ordered.filter { $0.grounding == .unsupported }.count
        report.ownersDropped = ordered.filter { $0.ownerClaim != nil && $0.ownerText == nil }.count
        let elapsed = ContinuousClock.now - began
        report.milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        Self.log.notice("""
            facts for note \(noteId): \(report.chunks) chunk(s), \(report.calls) call(s), \(report.failedChunks) failed, \
            \(report.records) record(s), \(report.verified) verified, \(report.unsupported) unsupported, \
            \(report.ownersDropped) owner(s) left blank, \(report.preempted) gave way, \(Int(report.milliseconds)) ms
            """)
        return (ordered, report)
    }

    /// The speakers as the prompt lists them: every label the transcript shows, with its stored speaker.
    public static func speakers(of transcript: NoteTranscript) -> [MeetingFactGrounder.Speaker] {
        var seen: [String: Int64?] = [:]
        var order: [String] = []
        for line in MeetingExtractPrompt.lines(of: transcript) {
            guard let label = line.speaker else { continue }
            if seen[label] == nil {
                seen[label] = line.parts.first?.turn.speakerId
                order.append(label)
            }
        }
        return order.map { MeetingFactGrounder.Speaker(label: $0, speakerId: seen[$0] ?? nil) }
    }

    /// The adapter's own schema on the local model; the string-only twin where guided generation has no null.
    private var usesNullableSchema: Bool {
        if let meeting = model as? MeetingLanguageModel { return meeting.route == .sharedLocal }
        return !model.identifier.lowercased().contains("apple")
    }

    /// One chunk: greedy, then once more with sampling; a dictation that cuts a call short is waited out and asked
    /// again, up to `maxPreemptionsPerChunk` times.
    private func call(_ prompt: String, schema: GenerationSchemaSpec, report: inout Report) async -> MeetingExtractAnswer? {
        var preemptions = 0
        for options in [LanguageModelOptions.greedy, .systemDefault] {
            while true {
                if Task.isCancelled { return nil }
                await model.yieldToForeground()
                report.calls += 1
                do {
                    let json = try await model.respond(
                        instructions: MeetingExtractPrompt.instructions, prompt: prompt, schema: schema, options: options)
                    if let answer = Self.decode(json) { return answer }
                    break
                } catch is ForegroundPreempted {
                    report.preempted += 1
                    preemptions += 1
                    if preemptions >= maxPreemptionsPerChunk { return nil }
                } catch {
                    Self.log.error("a facts call failed: \(String(describing: error), privacy: .public)")
                    break
                }
            }
        }
        return nil
    }

    /// The answer's records; a malformed answer (cut at the token cap) keeps nothing.
    static func decode(_ json: String) -> MeetingExtractAnswer? {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(MeetingExtractAnswer.self, from: Data(json[start...end].utf8))
    }
}

/// The Run A meeting-extract LoRA (`.build/meeting-extract-v1c/peft-adapter`, r32/α64 on the merged r10d, trained on
/// commercially usable AMI, ICSI and NOTSOFAR rows). It fits only `ModelRegistry.hushyCleanup4B` (and its sealed twin).
public enum MeetingExtractAdapter {
    public static let name = "meeting-extract-v1c"
    public static let extractorName = "r10d+meeting-extract-v1c/p1"
    /// Where an installed adapter lives: `<models root>/Models/meeting-extract-v1c/` with the PEFT files.
    public static let folderName = name
    public static let requiredFiles = ["adapter_config.json", "adapter_model.safetensors"]

    /// The adapter folder when its files are present: `HUSHY_MEETING_EXTRACT_ADAPTER` (evals and harnesses), else the
    /// app's models folder. Nothing downloads it yet: hosting it is a separate, founder-approved upload.
    public static func installedDirectory(modelsRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates = [environment["HUSHY_MEETING_EXTRACT_ADAPTER"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                          modelsRoot.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(folderName, isDirectory: true)]
        return candidates.compactMap { $0 }.first { folder in
            requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }

    /// Whether `entryID` is the 4B the adapter was trained on.
    public static func fits(entryID: String) -> Bool {
        entryID == ModelRegistry.hushyCleanup4B || entryID == ModelRegistry.hushyCleanup4BSealed
    }
}
