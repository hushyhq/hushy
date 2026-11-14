import Testing
@testable import MurmurCore

@Suite("Timecode formatting")
struct TimecodeTests {
    @Test("SRT uses comma decimal separator")
    func srtSeparator() {
        #expect(Timecode.srt(1.5) == "00:00:01,500")
    }

    @Test("VTT uses dot decimal separator")
    func vttSeparator() {
        #expect(Timecode.vtt(1.5) == "00:00:01.500")
    }

    @Test("Hours roll over correctly")
    func hours() {
        #expect(Timecode.srt(3661.25) == "01:01:01,250")
        #expect(Timecode.vtt(3661.25) == "01:01:01.250")
    }

    @Test("Zero and negative seconds clamp to zero")
    func zeroAndNegative() {
        #expect(Timecode.srt(0) == "00:00:00,000")
        #expect(Timecode.srt(-5) == "00:00:00,000")
    }

    @Test("Millisecond rounding")
    func rounding() {
        // 1.9999s should round up to the next second, not truncate to 999ms.
        #expect(Timecode.srt(1.9999) == "00:00:02,000")
    }

    @Test("Plain timecode omits hours under an hour")
    func plainShort() {
        #expect(Timecode.plain(65) == "1:05")
        #expect(Timecode.plain(5) == "0:05")
    }

    @Test("Plain timecode includes hours over an hour")
    func plainLong() {
        #expect(Timecode.plain(3665) == "1:01:05")
    }
}

@Suite("SubtitleFormatter cue packing (word-level, unattributed)")
struct SubtitleFormatterCueTests {
    private func words(_ strings: [(String, Double, Double)]) -> [WordTiming] {
        strings.map { WordTiming(word: $0.0, start: $0.1, end: $0.2) }
    }

    @Test("Empty input produces no cues")
    func empty() {
        let none: [WordTiming] = []
        #expect(SubtitleFormatter.cues(from: none).isEmpty)
    }

    @Test("Blank-text words are skipped")
    func blankWords() {
        let input = words([("hello", 0, 0.5), ("", 0.5, 0.6), ("  ", 0.6, 0.7), ("world", 0.7, 1.0)])
        let cues = SubtitleFormatter.cues(from: input)
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["hello world"])
    }

    @Test("A short utterance fits on one line, one cue")
    func shortUtterance() {
        let input = words([("Hello", 0, 0.3), ("there", 0.3, 0.6)])
        let cues = SubtitleFormatter.cues(from: input)
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["Hello there"])
        #expect(cues[0].startSeconds == 0)
        #expect(cues[0].endSeconds == 0.6)
    }

    @Test("Lines never exceed the character limit")
    func lineLengthLimit() {
        let longWords = (0..<20).map { ("word\($0)", Double($0), Double($0) + 0.9) }
        let cues = SubtitleFormatter.cues(from: words(longWords), options: .init(maxCharsPerLine: 20, maxLinesPerCue: 2, maxCueSeconds: 100))
        for cue in cues {
            for line in cue.lines {
                #expect(line.count <= 20)
            }
        }
    }

    @Test("A cue never exceeds the configured line count")
    func lineCountLimit() {
        let longWords = (0..<30).map { ("w\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.15) }
        let cues = SubtitleFormatter.cues(from: words(longWords), options: .init(maxCharsPerLine: 10, maxLinesPerCue: 2, maxCueSeconds: 100))
        for cue in cues {
            #expect(cue.lines.count <= 2)
        }
    }

    @Test("A cue never exceeds the configured duration")
    func durationLimit() {
        // Ten words spread over 20 seconds; maxCueSeconds = 5 should force multiple cues.
        let spread = (0..<10).map { ("word\($0)", Double($0) * 2, Double($0) * 2 + 1.5) }
        let cues = SubtitleFormatter.cues(from: words(spread), options: .init(maxCharsPerLine: 1000, maxLinesPerCue: 5, maxCueSeconds: 5))
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.endSeconds - cue.startSeconds <= 5.01)
        }
    }

    @Test("A single word longer than the line limit is kept whole")
    func overlongWord() {
        let input = words([("supercalifragilisticexpialidocious", 0, 1)])
        let cues = SubtitleFormatter.cues(from: input, options: .init(maxCharsPerLine: 10, maxLinesPerCue: 2, maxCueSeconds: 7))
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["supercalifragilisticexpialidocious"])
    }

    @Test("Cue timing spans first word start to last word end")
    func cueTimingSpan() {
        let input = words([("one", 1.0, 1.5), ("two", 1.6, 2.0)])
        let cues = SubtitleFormatter.cues(from: input)
        #expect(cues[0].startSeconds == 1.0)
        #expect(cues[0].endSeconds == 2.0)
    }
}

@Suite("SubtitleFormatter cue packing (speaker turns)")
struct SubtitleFormatterSpeakerCueTests {
    private func turn(_ text: String, _ start: Double, _ end: Double, speaker: NoteSpeaker?) -> NoteSegmentWithSpeaker {
        NoteSegmentWithSpeaker(
            segment: NoteSegment(noteId: 1, speakerId: speaker?.id, startTime: start, endTime: end, text: text, ordinal: 0),
            speaker: speaker)
    }

    @Test("A speaker-attributed turn is prefixed with its display label")
    func speakerPrefix() {
        let speaker = NoteSpeaker(id: 1, noteId: 1, label: "Speaker 1")
        let cues = SubtitleFormatter.cues(from: [turn("Hello there", 0, 1, speaker: speaker)])
        #expect(cues[0].lines == ["Speaker 1: Hello there"])
    }

    @Test("A renamed speaker uses the display name, not the raw label")
    func renamedSpeakerPrefix() {
        let speaker = NoteSpeaker(id: 1, noteId: 1, label: "Speaker 1", displayName: "Alex")
        let cues = SubtitleFormatter.cues(from: [turn("Hello there", 0, 1, speaker: speaker)])
        #expect(cues[0].lines == ["Alex: Hello there"])
    }

    @Test("An unattributed turn (import, or no diarization) has no prefix")
    func noPrefixWhenUnattributed() {
        let cues = SubtitleFormatter.cues(from: [turn("Hello there", 0, 1, speaker: nil)])
        #expect(cues[0].lines == ["Hello there"])
    }

    @Test("A speaker change always starts a new cue, never mixing two speakers")
    func speakerChangeStartsNewCue() {
        let speakerA = NoteSpeaker(id: 1, noteId: 1, label: "Speaker 1")
        let speakerB = NoteSpeaker(id: 2, noteId: 1, label: "Speaker 2")
        let cues = SubtitleFormatter.cues(from: [
            turn("Hi there", 0, 1, speaker: speakerA),
            turn("Hello back", 1, 2, speaker: speakerB),
        ])
        #expect(cues.count == 2)
        #expect(cues[0].lines == ["Speaker 1: Hi there"])
        #expect(cues[1].lines == ["Speaker 2: Hello back"])
    }
}

@Suite("SubtitleFormatter file rendering")
struct SubtitleFormatterRenderTests {
    private let sampleCues = [
        SubtitleFormatter.Cue(lines: ["Hello there"], startSeconds: 0, endSeconds: 1.2),
        SubtitleFormatter.Cue(lines: ["General Kenobi"], startSeconds: 1.3, endSeconds: 2.5),
    ]

    @Test("SRT numbers cues sequentially starting at 1")
    func srtNumbering() {
        let output = SubtitleFormatter.srt(cues: sampleCues)
        #expect(output.contains("1\n00:00:00,000 --> 00:00:01,200\nHello there"))
        #expect(output.contains("2\n00:00:01,300 --> 00:00:02,500\nGeneral Kenobi"))
    }

    @Test("SRT separates cues with a blank line")
    func srtBlankLineSeparator() {
        let output = SubtitleFormatter.srt(cues: sampleCues)
        #expect(output.contains("Hello there\n\n2\n"))
    }

    @Test("Empty cues produce an empty SRT string")
    func srtEmpty() {
        #expect(SubtitleFormatter.srt(cues: []).isEmpty)
    }

    @Test("VTT starts with the WEBVTT header")
    func vttHeader() {
        let output = SubtitleFormatter.vtt(cues: sampleCues)
        #expect(output.hasPrefix("WEBVTT\n\n"))
    }

    @Test("VTT uses dot timecodes and lists lines under each cue")
    func vttBody() {
        let output = SubtitleFormatter.vtt(cues: sampleCues)
        #expect(output.contains("00:00:00.000 --> 00:00:01.200\nHello there"))
        #expect(output.contains("00:00:01.300 --> 00:00:02.500\nGeneral Kenobi"))
    }

    @Test("Multi-line cue renders each line on its own row")
    func multiLineCue() {
        let cue = SubtitleFormatter.Cue(lines: ["Line one", "Line two"], startSeconds: 0, endSeconds: 1)
        let srt = SubtitleFormatter.srt(cues: [cue])
        #expect(srt.contains("Line one\nLine two"))
        let vtt = SubtitleFormatter.vtt(cues: [cue])
        #expect(vtt.contains("Line one\nLine two"))
    }
}

@Suite("PlainTextExporter")
struct PlainTextExporterTests {
    @Test("Groups words into timestamped lines")
    func groupsWithTimestamps() {
        let words = [
            WordTiming(word: "Hello", start: 0, end: 0.5),
            WordTiming(word: "there", start: 0.5, end: 1.0),
        ]
        let text = PlainTextExporter.timestampedText(rows: words)
        #expect(text == "[0:00] Hello there")
    }

    @Test("Empty word list produces empty text")
    func emptyWords() {
        let none: [WordTiming] = []
        #expect(PlainTextExporter.timestampedText(rows: none).isEmpty)
    }

    @Test("Long transcripts split into multiple timestamped lines")
    func multipleLines() {
        let words = (0..<20).map {
            WordTiming(word: "word\($0)", start: Double($0), end: Double($0) + 0.9)
        }
        let text = PlainTextExporter.timestampedText(rows: words, maxCharsPerLine: 20)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count > 1)
        for line in lines {
            #expect(line.hasPrefix("["))
        }
    }

    @Test("A speaker-attributed row is prefixed with its label")
    func speakerPrefix() {
        let speaker = NoteSpeaker(id: 1, noteId: 1, label: "Speaker 1")
        let row = NoteSegmentWithSpeaker(
            segment: NoteSegment(noteId: 1, speakerId: 1, startTime: 0, endTime: 1, text: "Hello there", ordinal: 0),
            speaker: speaker)
        let text = PlainTextExporter.timestampedText(rows: [row])
        #expect(text == "[0:00] Speaker 1: Hello there")
    }

    @Test("Untimed plain text passes through unchanged")
    func untimedPassthrough() {
        #expect(PlainTextExporter.plainText("Hello world") == "Hello world")
    }
}
