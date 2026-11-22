import Foundation

/// The meeting-extract prompt, ported byte for byte from `scripts/meeting-extract/build_sft.py` (`INSTRUCTIONS`,
/// `SCHEMA_JSON`, `user_turn`) and its chunker from `common.py` (`chunk_turns`). The Run A adapter
/// (`.build/meeting-extract-v1c/peft-adapter`) was trained on exactly this text, so changing it means retraining:
/// `MeetingExtractPromptCrosscheckTests` pins `sha256(system)` to the Python `SYSTEM_SHA256`.
public enum MeetingExtractPrompt {
    /// The schema name the MLX engine turns the extract adapter on for, and off for every other call.
    public static let schemaName = "MeetingRecords"

    public static let instructions = """
        You extract the records a careful minute-taker would write down from one chunk of a meeting transcript.
        The user message gives the meeting's title, kind, speakers and the chunk position, then the transcript, one line per turn.
        Kinds: decision is a settled choice or agreement, including a fixed constraint from the person running the meeting. action is a task someone takes on or is given, with or without an owner or a time. open_question is a question the participants say is unresolved and must come back. change reverses, cancels, reschedules or reassigns something already settled.
        text is one self-contained sentence, as a summary would write it. quote is copied exactly from one turn, 3 to 80 words, without the timestamp or the speaker. owner is a speaker label from the list, only for an action someone took, else null. due is the deadline words as spoken, else null.
        Never invent names, numbers, dates or owners. List records in the order they occur. If the chunk holds none, return an empty list.
        """

    /// The schema the adapter was trained to answer (owner and due nullable).
    public static let schema = GenerationSchemaSpec(name: schemaName, json: #"{"additionalProperties":false,"properties":{"records":{"description":"The records in transcript order, or empty","items":{"additionalProperties":false,"properties":{"kind":{"enum":["decision","action","open_question","change"],"type":"string"},"text":{"type":"string"},"owner":{"anyOf":[{"type":"string"},{"type":"null"}]},"due":{"anyOf":[{"type":"string"},{"type":"null"}]},"quote":{"type":"string"}},"required":["kind","text","owner","due","quote"],"type":"object","x-order":["kind","text","owner","due","quote"]},"type":"array"}},"required":["records"],"title":"MeetingRecords","type":"object","x-order":["records"]}"#)

    /// The same answer for a backend whose guided generation has no nullable fields (Apple FM): an empty owner or due
    /// means none.
    public static let plainSchema = GenerationSchemaSpec(name: schemaName, json: #"{"additionalProperties":false,"properties":{"records":{"description":"The records in transcript order, or empty","items":{"additionalProperties":false,"title":"MeetingRecord","properties":{"kind":{"enum":["decision","action","open_question","change"],"type":"string"},"text":{"type":"string"},"owner":{"description":"A speaker label, or empty","type":"string"},"due":{"description":"The deadline words as spoken, or empty","type":"string"},"quote":{"type":"string"}},"required":["kind","text","owner","due","quote"],"type":"object","x-order":["kind","text","owner","due","quote"]},"type":"array"}},"required":["records"],"title":"MeetingRecords","type":"object","x-order":["records"]}"#)

    /// The system message as the MLX backend sends it (`MLXLanguageModel.systemText`): the training `SYSTEM`.
    public static var system: String {
        """
        \(instructions)

        Reply with only a JSON object that conforms to this JSON schema (each field's description \
        says what goes in it):
        \(schema.json)
        """
    }

    /// One chunk's user message, as `build_sft.user_turn` writes it.
    public static func userTurn(title: String, kind: String, speakers: [String], chunk: String, transcript: String) -> String {
        let named = speakers.isEmpty ? "not labelled" : speakers.joined(separator: ", ")
        return "Meeting: \(title) (\(kind))\nSpeakers: \(named)\nChunk: \(chunk)\n\nTranscript:\n\(transcript)\n\nExtract the records."
    }

    /// "[04:05] " or "[1:02:10] " before a turn, as `common.stamp` writes it; empty without a time.
    public static func stamp(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "[%d:%02d:%02d] ", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "[%02d:%02d] ", s / 60, s % 60)
    }

    /// One transcript line of a chunk.
    public struct Line: Sendable, Equatable {
        public var speaker: String?
        public var start: Double?
        public var text: String
        /// The stored turns this line was made of, in order, and where each begins in `text` (UTF-16).
        public var parts: [Part]

        public struct Part: Sendable, Equatable {
            public var turn: NoteTurn
            public var offset: Int
        }

        public init(speaker: String?, start: Double?, text: String, parts: [Part] = []) {
            self.speaker = speaker
            self.start = start
            self.text = text
            self.parts = parts
        }

        public var rendered: String { MeetingExtractPrompt.stamp(start) + (speaker.map { "\($0): " } ?? "") + text }
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Chunk sizes in words: about 1,800 at turn boundaries for the 4B (training), a smaller window for Apple FM's
    /// 4,096 tokens.
    public struct Size: Sendable, Equatable {
        public var target: Int
        public var max: Int
        public var minLast: Int
        public static let training = Size(target: 1_800, max: 2_600, minLast: 600)
        public static let smallWindow = Size(target: 900, max: 1_300, minLast: 300)

        public static func forContext(tokens: Int) -> Size { tokens >= 8_192 ? .training : .smallWindow }
    }

    /// `common.chunk_turns`: greedy chunks of about `size.target` words at line boundaries; a short tail joins the
    /// previous chunk.
    public static func chunks(_ lines: [Line], size: Size = .training) -> [[Line]] {
        var chunks: [[Line]] = []
        var current: [Line] = []
        var count = 0
        for line in lines {
            let n = line.words
            if !current.isEmpty, count >= size.target || count + n > size.max {
                chunks.append(current)
                current = []
                count = 0
            }
            current.append(line)
            count += n
        }
        if !current.isEmpty {
            let tailWords = current.reduce(0) { $0 + $1.words }
            if let last = chunks.last, tailWords < size.minLast,
               last.reduce(0, { $0 + $1.words }) + tailWords <= size.max + 400 {
                chunks[chunks.count - 1] = last + current
            } else {
                chunks.append(current)
            }
        }
        return chunks
    }

    /// The transcript's shown lines (consecutive turns of one voice merged, `NoteTranscript.lines`) with the turns
    /// each was made of, so a quote found in a line maps back to one stored turn.
    public static func lines(of transcript: NoteTranscript) -> [Line] {
        let labelled = transcript.hasSeveralVoices
        var lines: [Line] = []
        var lastVoice: NoteTranscript.Voice?
        for turn in transcript.turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let voice = NoteTranscript.voice(of: turn)
            if !lines.isEmpty, voice == lastVoice || !labelled {
                let offset = (lines[lines.count - 1].text as NSString).length + 1
                lines[lines.count - 1].text += " " + text
                lines[lines.count - 1].parts.append(.init(turn: turn, offset: offset))
            } else {
                lines.append(Line(
                    speaker: labelled ? transcript.label(of: turn) : nil, start: turn.t0, text: text,
                    parts: [.init(turn: turn, offset: 0)]))
            }
            lastVoice = voice
        }
        return lines
    }
}

/// The adapter's answer: records for one chunk.
public struct MeetingExtractAnswer: StructuredOutput, Equatable {
    public struct Record: Codable, Sendable, Equatable {
        public var kind: String
        public var text: String
        public var owner: String?
        public var due: String?
        public var quote: String

        public init(kind: String, text: String, owner: String? = nil, due: String? = nil, quote: String) {
            self.kind = kind
            self.text = text
            self.owner = owner
            self.due = due
            self.quote = quote
        }
    }

    public var records: [Record]

    public init(records: [Record]) { self.records = records }

    public static let generationSchema = MeetingExtractPrompt.schema
}
