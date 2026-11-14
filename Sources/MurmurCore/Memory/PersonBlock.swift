import Foundation

public struct PersonBlock: Sendable, Equatable {
    public var profile: String?
    public var style: String?
    public var terms: [String]
    public var earlier: [String]
    public var edits: [(before: String, after: String)]
    public var screen: String?

    public init(profile: String? = nil, style: String? = nil, terms: [String] = [],
                earlier: [String] = [], edits: [(before: String, after: String)] = [], screen: String? = nil) {
        self.profile = profile
        self.style = style
        self.terms = terms
        self.earlier = earlier
        self.edits = edits
        self.screen = screen
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.render() == rhs.render() }
    public var usedLines: Int { lines.count }

    /// Words actually visible in the rendered block. Labels and clipped-away text are not sources.
    var spellingWords: Set<String> {
        guard let rendered = render() else { return [] }
        return Self.spellingWords(in: rendered)
    }

    static func spellingWords(in rendered: String) -> Set<String> {
        let labels = ["How they write: ", "Words they use: ", "Just before, in this app: ", "Their edits: ", "On screen: "]
        let contents = rendered.components(separatedBy: "\n").dropFirst().map { line in
            guard let label = labels.first(where: line.hasPrefix) else { return line }
            return String(line.dropFirst(label.count))
        }.joined(separator: " ")
        return Set(OutputGuard.words(contents).map { $0.lowercased() })
    }

    /// The block as the model was trained to read it: the heading, then each known line in this
    /// order. Nil when nothing is known, so the user turn starts at the transcript.
    public func render() -> String? {
        let lines = self.lines
        return lines.isEmpty ? nil : (["About this person"] + lines).joined(separator: "\n")
    }

    private var lines: [String] {
        var lines: [String] = []
        let voice = [profile, style].compactMap { $0.flatMap(Self.line) }.joined(separator: "; ")
        if !voice.isEmpty { lines.append("How they write: " + voice) }
        let words = terms.prefix(11).compactMap(Self.line)
        if !words.isEmpty { lines.append("Words they use: " + words.joined(separator: "; ")) }
        // Oldest first; when there are more than three, the three nearest the transcript.
        let previous = earlier.suffix(3).compactMap(Self.quoted)
        if !previous.isEmpty { lines.append("Just before, in this app: " + previous.map { "\"\($0)\"" }.joined(separator: " / ")) }
        // Oldest first too, so the three kept are the most recent.
        let pairs = edits.suffix(3).compactMap { pair -> String? in
            guard let before = Self.quoted(pair.before), let after = Self.quoted(pair.after) else { return nil }
            return "\"\(before)\" -> \"\(after)\""
        }
        if !pairs.isEmpty { lines.append("Their edits: " + pairs.joined(separator: " / ")) }
        if let screen = screen.flatMap(Self.screenText) { lines.append("On screen: " + screen) }
        return lines
    }

    /// The value on one line, cut at the limit.
    private static func line(_ value: String) -> String? {
        let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(limit))
    }

    /// A value that goes inside double quotes (an earlier dictation, an edit): a double quote in
    /// it becomes a single one, so it cannot close them early.
    private static func quoted(_ value: String) -> String? {
        line(value)?.replacingOccurrences(of: "\"", with: "'", options: .literal)
    }

    /// Screen text as it is, as in training: the window title, then the text lines. Only the
    /// space at the ends of each line goes, and blank lines.
    private static func screenText(_ value: String) -> String? {
        let text = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    private static let limit = 1_500
}
