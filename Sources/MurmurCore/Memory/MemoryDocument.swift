import Foundation

public struct MemoryEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case profile, term, forgotten, style, correction }
    /// Who put an entry there. What Hushy learned goes with "Delete learning data"; what the
    /// person typed, or changed in any way, is theirs and stays.
    public enum Origin: String, Sendable { case learned, typed }
    public var id: UUID
    public var kind: Kind
    public var value: String
    public var heardAs: [String]
    public var appBundleID: String?
    /// To the second: the files hold dates as text, and an entry must equal itself read back.
    public var createdAt: Date
    public var before: String?
    public var after: String?
    /// Nil only for an entry read from a file written before origins were recorded.
    public var origin: Origin?

    public init(id: UUID = UUID(), kind: Kind, value: String, heardAs: [String] = [],
                appBundleID: String? = nil, createdAt: Date = Date(), before: String? = nil, after: String? = nil,
                origin: Origin? = .typed) {
        self.id = id
        self.kind = kind
        self.value = value
        self.heardAs = heardAs
        self.appBundleID = appBundleID
        self.createdAt = Self.toTheSecond(createdAt)
        self.before = before
        self.after = after
        self.origin = origin
    }

    /// The same before and after, in the same app.
    func isSameChange(as other: MemoryEntry) -> Bool {
        kind == .correction && other.kind == .correction && appBundleID == other.appBundleID
            && before == other.before && after == other.after
    }

    static func toTheSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }
}

/// One memory file as the person can read and edit it. A line that starts with a dash and a
/// space is one entry, and its text is the entry: a word in `terms.md`, a note in `profile.md`
/// or `style/<app>.md`. What kind it is comes from where it is (the file, and in `terms.md`
/// whether it sits under the "Forgotten" heading), so moving or retyping a line is all an edit
/// takes. After the text Hushy keeps a hidden note, `<!-- hushy:{…} -->`: an id, the date, for
/// a word how it was misheard, and who put the line there. A line typed by hand has no note
/// until `adopt` gives it one. A line Hushy learned carries a mark of its text as learned, so a
/// line the person has since retyped reads as theirs. Everything else (headings, prose, a line whose note is damaged) is kept exactly as it is.
public struct MemoryDocument: Sendable, Equatable {
    public enum File: Sendable, Equatable {
        case profile, terms, corrections
        /// `style/<app>.md`; the app comes from the file's name.
        case style(app: String?)
    }

    public static let profileLimit = 1_500
    public let file: File
    public var lines: [String]

    public init(_ text: String = "", file: File) {
        self.file = file
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    public var entries: [MemoryEntry] { bullets.compactMap(\.entry) }
    public var isPaused: Bool { lines.contains(Self.pausedLine) }
    public var text: String { lines.joined(separator: "\n") }

    /// Gives every hand-typed line its hidden note (a new id, `now` as its date), and notes a
    /// learned line the person has retyped as theirs; what was typed is left untouched. True
    /// when a line changed and the file should be written back.
    public mutating func adopt(now: Date = Date()) -> Bool {
        let changed = bullets.filter { $0.isTyped || $0.retyped != nil }
        for bullet in changed {
            var note = bullet.retyped ?? MemoryNote(created: MemoryEntry.toTheSecond(now), id: UUID())
            note.origin = MemoryEntry.Origin.typed.rawValue
            note.mark = nil
            guard let json = note.json else { continue }
            let line = lines[bullet.line]
            // Only the note changes: the text before it stays exactly as it was typed.
            let text = bullet.isTyped ? line + " " : String(line[..<(line.range(of: Self.marker, options: .backwards)?.lowerBound ?? line.endIndex)])
            lines[bullet.line] = text + Self.marker + json + " -->"
        }
        return !changed.isEmpty
    }

    public mutating func append(_ entry: MemoryEntry) {
        guard let line = encode(entry, prefix: "- ") else { return }
        if entry.kind == .forgotten && forgottenHeading == nil {
            if lines.last.map({ !$0.isEmpty }) ?? false { lines.append("") }
            lines.append(Self.forgottenTitle)
        }
        lines.insert(line, at: insertionPoint(for: entry.kind))
    }

    public mutating func replace(_ entry: MemoryEntry) {
        guard let bullet = bullets.first(where: { $0.entry?.id == entry.id }),
              let line = encode(entry, prefix: bullet.prefix) else { return }
        lines[bullet.line] = line
    }

    public mutating func remove(id: UUID) {
        guard let bullet = bullets.first(where: { $0.entry?.id == id }) else { return }
        lines.remove(at: bullet.line)
    }

    public mutating func setPaused(_ paused: Bool) {
        lines.removeAll { $0 == Self.pausedLine }
        if paused { lines.append(Self.pausedLine) }
    }

    // MARK: Reading

    private static let pausedLine = "<!-- hushy:paused -->"
    private static let forgottenTitle = "## Forgotten"
    private static let marker = "<!-- hushy:"

    /// One "- " line: where it is, what it would be, and the entry when it is complete.
    private struct Bullet {
        let line: Int
        let kind: MemoryEntry.Kind
        let prefix: String
        /// Typed by hand: there is text and no hidden note yet.
        let isTyped: Bool
        /// The note of a learned line whose text is no longer what Hushy wrote.
        let retyped: MemoryNote?
        let entry: MemoryEntry?
    }

    private var bullets: [Bullet] {
        var found: [Bullet] = []
        var isInComment = false, isForgotten = false
        for (index, line) in lines.enumerated() {
            if isInComment {
                isInComment = !line.contains("-->")
            } else if line.hasPrefix("<!--") {
                isInComment = !line.contains("-->")
            } else if line.hasPrefix("#") {
                isForgotten = Self.isForgottenHeading(line)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                found.append(bullet(line, at: index, isForgotten: isForgotten))
            }
        }
        return found
    }

    private func bullet(_ line: String, at index: Int, isForgotten: Bool) -> Bullet {
        let kind = kind(isForgotten: isForgotten)
        let body = line.dropFirst(2)
        let noteStart = body.hasSuffix("-->") ? body.range(of: Self.marker, options: .backwards) : nil
        let visible = String(body[..<(noteStart?.lowerBound ?? body.endIndex)]).trimmingCharacters(in: .whitespaces)
        var entry: MemoryEntry?
        var retyped: MemoryNote?
        if let noteStart, let note = MemoryNote(json: body[noteStart.upperBound...].dropLast(3)) {
            entry = self.entry(kind, visible: visible, note: note)
            if entry != nil, note.isLearned, !note.isLearned(as: visible) { retyped = note }
        }
        // A correction is a pair, which only the note holds; a hand-typed one cannot be read.
        let isTyped = noteStart == nil && !visible.isEmpty && kind != .correction
        return Bullet(line: index, kind: kind, prefix: String(line.prefix(2)), isTyped: isTyped, retyped: retyped, entry: entry)
    }

    private func entry(_ kind: MemoryEntry.Kind, visible: String, note: MemoryNote) -> MemoryEntry? {
        if kind == .correction {
            guard note.before != nil, note.after != nil else { return nil }
            return MemoryEntry(id: note.id, kind: kind, value: "", appBundleID: note.app, createdAt: note.created,
                               before: note.before, after: note.after, origin: note.origin(of: visible))
        }
        guard !visible.isEmpty else { return nil }
        return MemoryEntry(id: note.id, kind: kind, value: visible, heardAs: note.heardAs ?? [],
                           appBundleID: note.app ?? fileApp, createdAt: note.created, origin: note.origin(of: visible))
    }

    private func kind(isForgotten: Bool) -> MemoryEntry.Kind {
        switch file {
        case .profile: .profile
        case .terms: isForgotten ? .forgotten : .term
        case .corrections: .correction
        case .style: .style
        }
    }

    private var fileApp: String? {
        if case .style(let app) = file { return app }
        return nil
    }

    private static func isForgottenHeading(_ line: String) -> Bool {
        line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() == "forgotten"
    }

    // MARK: Writing

    private var forgottenHeading: Int? {
        guard file == .terms else { return nil }
        return lines.firstIndex { $0.hasPrefix("#") && Self.isForgottenHeading($0) }
    }

    /// A word goes at the end of the words above "Forgotten", a forgotten word at the end of
    /// that section, anything else at the end of the file; never below trailing blank lines.
    private func insertionPoint(for kind: MemoryEntry.Kind) -> Int {
        var end = lines.count
        if let heading = forgottenHeading {
            if kind == .term {
                end = heading
            } else if kind == .forgotten {
                end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
            }
        }
        while end > 0, lines[end - 1].isEmpty { end -= 1 }
        return end
    }

    private func encode(_ entry: MemoryEntry, prefix: String) -> String? {
        let isPair = entry.kind == .correction
        let shown = isPair ? "\"\(entry.before ?? "")\" → \"\(entry.after ?? "")\"" : entry.value
        let visible = shown.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // The file's name already says which app a style note is for.
        let app = entry.appBundleID == fileApp ? nil : entry.appBundleID
        var note = MemoryNote(after: isPair ? entry.after : nil, app: app, before: isPair ? entry.before : nil,
                              created: entry.createdAt, heardAs: entry.heardAs.isEmpty ? nil : entry.heardAs, id: entry.id)
        note.origin = entry.origin?.rawValue
        note.mark = entry.origin == .learned ? MemoryNote.mark(of: visible) : nil
        guard !visible.isEmpty, let json = note.json else { return nil }
        return prefix + visible + " " + Self.marker + json + " -->"
    }
}

/// The hidden note after an entry's text. Keys are written in alphabetical order and the date
/// as text, so a file changes only where an entry did.
private struct MemoryNote: Codable {
    var after: String?
    var app: String?
    var before: String?
    var created: Date
    var heardAs: [String]?
    var id: UUID
    /// For a learned line: a mark of its text as Hushy wrote it (see `mark(of:)`).
    var mark: String?
    /// "learned" or "typed"; absent in a file from before origins were recorded.
    var origin: String?

    var isLearned: Bool { origin == MemoryEntry.Origin.learned.rawValue }

    /// Still the text Hushy wrote.
    func isLearned(as visible: String) -> Bool { isLearned && mark == Self.mark(of: visible) }

    /// A learned line the person has retyped is theirs.
    func origin(of visible: String) -> MemoryEntry.Origin? {
        if isLearned { return isLearned(as: visible) ? .learned : .typed }
        return origin.flatMap(MemoryEntry.Origin.init(rawValue:))
    }

    /// Eight hex digits that change when the text does (FNV-1a over its UTF-8 bytes): enough to
    /// tell "as Hushy wrote it" from "retyped", and nothing more is asked of it.
    static func mark(of text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    init(after: String? = nil, app: String? = nil, before: String? = nil, created: Date,
         heardAs: [String]? = nil, id: UUID) {
        self.after = after
        self.app = app
        self.before = before
        self.created = created
        self.heardAs = heardAs
        self.id = id
    }

    init?(json: some StringProtocol) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let note = try? decoder.decode(MemoryNote.self, from: Data(json.utf8)) else { return nil }
        self = note
    }

    /// Angle brackets are written as escapes, so nothing inside the note can end the comment or
    /// look like the start of another one.
    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
    }
}
