import Foundation

/// How many paragraph breaks and line breaks a text has, as numbers only. The log carries these for the model's answer and
/// for the text that was delivered, so a dictation that came out as one block can be traced to the model or to a later
/// step without any of the words being logged.
public struct LineBreakCount: Sendable, Equatable {
    /// Blank-line gaps: runs of two or more newlines (a gap of three newlines is one).
    public let paragraphs: Int
    /// Every newline character, including the ones inside a paragraph gap.
    public let lines: Int

    public init(paragraphs: Int, lines: Int) {
        self.paragraphs = paragraphs
        self.lines = lines
    }

    public init(of text: String) {
        var gaps = 0, newlines = 0, run = 0
        for character in text.unicodeScalars {
            if character == "\n" {
                newlines += 1
                run += 1
                if run == 2 { gaps += 1 }
            } else if character != "\r" {
                run = 0
            }
        }
        self.init(paragraphs: gaps, lines: newlines)
    }

    public static func + (left: LineBreakCount, right: LineBreakCount) -> LineBreakCount {
        LineBreakCount(paragraphs: left.paragraphs + right.paragraphs, lines: left.lines + right.lines)
    }

    /// "paragraphs/lines", for example "2/2" for three paragraphs.
    public var logSummary: String { "\(paragraphs)/\(lines)" }
}
