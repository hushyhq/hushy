import Foundation
import MurmurCore

/// The clock `murmur-eval early-clean` runs a dictation on. The speech is not played back in real time: recogniser
/// passes and model calls take the time they really took, and the gaps between them are skipped. A model call starts
/// when its group is known and the model is free, as in the app (one early call at a time), and one that would start
/// at or after the key release is not made.
enum EarlySimulation {
    /// A transcript of the speech so far: its recogniser pass began at `start` seconds into the recording and the text
    /// was there at `ready`.
    struct Transcript: Equatable {
        let start: Double
        let ready: Double
        let text: String
    }

    struct Outcome: Equatable {
        var calls: [EarlyRecords.EarlyCall] = []
        var started: [String] = []
        var transcripts = 0
        var withdrawn = 0
        /// How long past the release the last early call ran.
        var inFlight = 0.0

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.started == rhs.started && lhs.transcripts == rhs.transcripts && lhs.withdrawn == rhs.withdrawn
                && lhs.inFlight == rhs.inFlight && lhs.calls.map(\.start) == rhs.calls.map(\.start)
        }
    }

    /// Which whole-recording passes run while speaking: the first at the first tick at or after `first` seconds, then
    /// one every `max(tick, stretch × audio so far)` seconds, and never two at once. `ticks` are the measured passes.
    static func passes(_ ticks: [EarlyRecords.Heard], first: Double, stretch: Double, tick: Double) -> [Transcript] {
        var schedule = EarlyPassSchedule(first: first, gap: tick, stretch: stretch)
        var out: [Transcript] = []
        var busyUntil = 0.0
        for pass in ticks {
            if schedule.isRunning, busyUntil <= pass.t { schedule.finished() }
            guard schedule.start(at: pass.t) else { continue }
            busyUntil = pass.t + pass.ms / 1_000
            out.append(Transcript(start: pass.t, ready: busyUntil, text: pass.text))
        }
        return out
    }

    /// How long past the release a recogniser pass that began before it is still running.
    static func blocked(_ transcripts: [Transcript], release: Double) -> Double {
        transcripts.filter { $0.start < release && $0.ready > release }.map { $0.ready - release }.max() ?? 0
    }

    /// Runs the early cleaning of one dictation. `clean` makes the real call for a group and returns its seconds.
    static func run(
        _ transcripts: [Transcript], release: Double, sightings: Int, clean: (String) async -> Double
    ) async -> Outcome {
        var queue = EarlyCleanupQueue(sightings: sightings)
        let arriving = transcripts.filter { $0.ready < release }.sorted { $0.ready < $1.ready }
        var next = 0
        var modelFree = 0.0
        var outcome = Outcome()
        while modelFree < release {
            while next < arriving.count, arriving[next].ready <= modelFree {
                queue.heard(arriving[next].text)
                next += 1
            }
            if let group = queue.next() {
                let seconds = await clean(group)
                outcome.calls.append(.init(start: modelFree, seconds: seconds))
                modelFree += seconds
            } else if next < arriving.count {
                modelFree = max(modelFree, arriving[next].ready)
            } else {
                break
            }
        }
        queue.close()
        outcome.started = queue.started
        outcome.transcripts = queue.transcripts
        outcome.withdrawn = queue.withdrawn
        outcome.inFlight = outcome.calls.last.map { max(0, $0.start + $0.seconds - release) } ?? 0
        return outcome
    }

    /// Today's app: each newly confirmed transcript has its closed groups cleaned in order, one at a time, each once.
    /// `clean` is given the group and the group before it.
    static func runLegacy(
        _ transcripts: [Transcript], release: Double, clean: (TextSegmentation.Group, String?) async -> Double
    ) async -> Outcome {
        var outcome = Outcome()
        var seen = Set<String>()
        var modelFree = 0.0
        for transcript in transcripts.filter({ $0.ready < release }).sorted(by: { $0.ready < $1.ready }) {
            outcome.transcripts += 1
            modelFree = max(modelFree, transcript.ready)
            let groups = TextSegmentation.groups(transcript.text)
            guard groups.count > 1 else { continue }
            for group in groups where !group.isTail && !seen.contains(group.text) {
                guard modelFree < release else { break }
                seen.insert(group.text)
                let seconds = await clean(group, group.index > 0 ? groups[group.index - 1].text : nil)
                outcome.calls.append(.init(start: modelFree, seconds: seconds))
                outcome.started.append(group.text)
                modelFree += seconds
            }
        }
        outcome.inFlight = outcome.calls.last.map { max(0, $0.start + $0.seconds - release) } ?? 0
        return outcome
    }

    /// The while-speaking recogniser as the app drives it today: nothing before the first tick at or after `activation`
    /// seconds, then its confirmed text at each tick where that text grew.
    static func legacyTranscripts(_ sliding: [EarlyRecords.Sliding], activation: Double) -> [Transcript] {
        var out: [Transcript] = []
        var last = ""
        for state in sliding where state.t >= activation && state.confirmed != last && !state.confirmed.isEmpty {
            out.append(Transcript(start: state.t, ready: state.t, text: state.confirmed))
            last = state.confirmed
        }
        return out
    }

    /// The same recogniser read from the start, with the text it has decoded but not yet confirmed.
    static func volatileTranscripts(_ sliding: [EarlyRecords.Sliding]) -> [Transcript] {
        var out: [Transcript] = []
        var last = ""
        for state in sliding {
            let text = [state.confirmed, state.volatile].filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty, text != last else { continue }
            out.append(Transcript(start: state.t, ready: state.t, text: text))
            last = text
        }
        return out
    }

    /// Text-only stand-in for a recogniser: at each tick, the words spoken so far at `wordsPerSecond`.
    static func spokenSoFar(_ text: String, wordsPerSecond: Double, tick: Double) -> (transcripts: [EarlyRecords.Heard], seconds: Double) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let seconds = Double(words.count) / wordsPerSecond
        var out: [EarlyRecords.Heard] = []
        var t = tick
        while t < seconds {
            out.append(.init(t: t, text: words.prefix(Int(t * wordsPerSecond)).joined(separator: " "), ms: 0))
            t += tick
        }
        return (out, seconds)
    }

    /// Text-only stand-in for today's while-speaking recogniser: a chunk of `chunk` seconds is decoded once `lookahead`
    /// more seconds exist, and its words are confirmed when the next chunk is decoded.
    static func slidingSoFar(
        _ text: String, wordsPerSecond: Double, tick: Double, chunk: Double = 11, lookahead: Double = 2
    ) -> [EarlyRecords.Sliding] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let seconds = Double(words.count) / wordsPerSecond
        func upTo(_ time: Double) -> String { words.prefix(Int(max(0, time) * wordsPerSecond)).joined(separator: " ") }
        var out: [EarlyRecords.Sliding] = []
        var t = tick
        while t < seconds {
            let decoded = t >= chunk + lookahead ? Int((t - chunk - lookahead) / chunk) + 1 : 0
            let confirmedText = upTo(Double(max(0, decoded - 1)) * chunk)
            let decodedText = upTo(Double(decoded) * chunk)
            out.append(.init(t: t, confirmed: confirmedText, volatile: String(decodedText.dropFirst(confirmedText.count)).trimmingCharacters(in: .whitespaces)))
            t += tick
        }
        return out
    }
}
