import Foundation

/// Builds a finished note's turns from every recognised word of both streams: the assembling step
/// of the meetings schema freeze (section 3). Pure, no model and no store.
///
/// - Every word that went in comes out, in exactly one turn. Mic words that are the call heard
///   through the speakers (`EchoDeduplicator`) stay in their turn's `words` with the echo flag and
///   are left out of its text.
/// - A two-channel note: the mic side is one speaker, the owner (a `micChannel` assignment); the
///   call side is split by `systemTurns` into "Speaker 1, 2, …" in order of first appearance, or is
///   all "Speaker 1" when diarization found nothing.
/// - A mic-only note with `micTurns`: the room is split the same way. Without them there is one
///   speaker.
/// - Turns follow time, and break at a speaker change or a pause of `pauseSeconds`. Time order is
///   by word midpoint; ties keep the mic first. O(n log n) in words.
public enum TurnAssembler {
    public static let pauseSeconds = 2.0

    public struct Speaker: Sendable, Equatable {
        public var label: String
        /// The mic side of a two-channel call: the person recording.
        public var isOwner: Bool
        /// The diarizer's own label for this speaker ("S2"), to find its voice; "owner" for the mic side.
        public var diarizerLabel: String
    }

    public struct Turn: Sendable, Equatable {
        public var speakerIndex: Int
        public var stream: NoteTurn.Stream
        public var t0: Double
        public var t1: Double
        public var words: [NoteTurn.Word]
        public var text: String
    }

    public struct Assembly: Sendable, Equatable {
        public var speakers: [Speaker]
        public var turns: [Turn]
        /// The owner's name for the `micChannel` assignment, when there is an owner.
        public var ownerName: String?

        /// Every word in the assembly, echo or not.
        public var wordCount: Int { turns.reduce(0) { $0 + $1.words.count } }
    }

    public static func assemble(
        mic: [WordTiming], system: [WordTiming], isTwoChannel: Bool, micTurns: [DiarizationTurn] = [],
        systemTurns: [DiarizationTurn] = [], ownerName: String? = nil, clean: (String) -> String = { $0 }
    ) -> Assembly {
        struct Tagged { var word: NoteTurn.Word; var stream: NoteTurn.Stream; var speaker: Int; var order: Int }
        var speakers: [Speaker] = []
        var tagged: [Tagged] = []
        let owner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The mic side is labelled with the owner's name from Settings, as the timed view always showed it.
        let ownerLabel = (owner?.isEmpty == false ? owner : nil) ?? NoteTranscript.micLabel

        func index(of label: String, owner: Bool, in table: inout [String: Int]) -> Int {
            if let known = table[label] { return known }
            speakers.append(Speaker(
                label: owner ? ownerLabel : "Speaker \(table.count + 1)", isOwner: owner, diarizerLabel: label))
            table[label] = speakers.count - 1
            return speakers.count - 1
        }

        var roomTable: [String: Int] = [:]
        if isTwoChannel {
            let echoes = echoIndexes(mic: mic, system: system)
            var ownerTable: [String: Int] = [:]
            for (i, word) in mic.enumerated() {
                let speaker = index(of: "owner", owner: true, in: &ownerTable)
                tagged.append(Tagged(word: stored(word, echo: echoes.contains(i)), stream: .mic, speaker: speaker, order: tagged.count))
            }
            let labels = SpeakerAlignment.labels(words: system, turns: systemTurns)
            for (word, label) in zip(system, labels) {
                let speaker = index(of: label, owner: false, in: &roomTable)
                tagged.append(Tagged(word: stored(word, echo: false), stream: .system, speaker: speaker, order: tagged.count))
            }
        } else {
            let labels = SpeakerAlignment.labels(words: mic, turns: micTurns)
            for (word, label) in zip(mic, labels) {
                let speaker = index(of: label, owner: false, in: &roomTable)
                tagged.append(Tagged(word: stored(word, echo: false), stream: .mic, speaker: speaker, order: tagged.count))
            }
        }

        tagged.sort {
            let a = ($0.word.start + $0.word.end) / 2, b = ($1.word.start + $1.word.end) / 2
            return a != b ? a < b : $0.order < $1.order
        }

        var turns: [Turn] = []
        for item in tagged {
            if var last = turns.last, last.speakerIndex == item.speaker, item.word.start - last.t1 < pauseSeconds {
                last.words.append(item.word)
                last.t1 = max(last.t1, item.word.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(
                    speakerIndex: item.speaker, stream: item.stream, t0: item.word.start, t1: item.word.end,
                    words: [item.word], text: ""))
            }
        }
        for i in turns.indices {
            let spoken = turns[i].words.filter { $0.flags & NoteTurn.Word.echo == 0 }.map(\.w).joined(separator: " ")
            turns[i].text = spoken.isEmpty ? "" : clean(spoken)
        }
        return Assembly(speakers: speakers, turns: turns, ownerName: speakers.contains(where: \.isOwner) ? ownerLabel : nil)
    }

    private static func stored(_ timing: WordTiming, echo: Bool) -> NoteTurn.Word {
        NoteTurn.Word(w: timing.word, start: timing.start, end: timing.end, conf: 1, flags: echo ? NoteTurn.Word.echo : 0)
    }

    /// Which mic words are the call side heard again through the speakers.
    static func echoIndexes(mic: [WordTiming], system: [WordTiming]) -> Set<Int> {
        guard !mic.isEmpty, !system.isEmpty else { return [] }
        let sortedSystem = system.map { StreamWord(timing: $0, stream: .systemAudio) }.sorted { $0.start < $1.start }
        var echoes: Set<Int> = []
        for (i, word) in mic.enumerated() where EchoDeduplicator.isEcho(
            of: StreamWord(timing: word, stream: .microphone), in: sortedSystem,
            timeTolerance: EchoDeduplicator.defaultTimeToleranceSeconds, energyHint: nil) {
            echoes.insert(i)
        }
        return echoes
    }
}
