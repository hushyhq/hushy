import Foundation

/// The founder-facing side of the head-to-head corpus (gate 12): a Markdown template with one
/// slot per paragraph that the founder dictates into **twice** — once with Hushy, once with the
/// competitor, manually — and a parser that turns two filled-in copies back into a pairs file.
///
/// The template is the transport for both sides on purpose: Hushy has no bulk history export,
/// and this harness must never read the app's database, so "dictate straight into the template
/// document" is the only path that needs no automation and no privileged file access.
enum HeadToHeadTemplate {
    enum Style: String, CaseIterable, Sendable {
        case work, email, chat, notes

        var cue: String {
            switch self {
            case .work: "a status update, a decision, or a plan for the week, as you would say it to a teammate"
            case .email: "a reply to someone: greeting, one or two points, a sign-off"
            case .chat: "a Slack or iMessage: casual, short sentences, maybe a question"
            case .notes: "a note to yourself: a thought, a list, a reminder, half-formed is fine"
            }
        }
    }

    struct Slot: Equatable, Sendable {
        let id: String
        let style: Style
        /// Slots that must run longer than 60 s of continuous speech (gate 12 asks for ≥ 20).
        let isLong: Bool
    }

    static let defaultCount = 100
    static let longEvery = 5

    /// Deterministic plan: a repeating 20-slot pattern interleaves the styles (6 work, 5 email,
    /// 5 chat, 4 notes per 20 — 30/25/25/20 over 100 slots) so the founder never dictates one
    /// register for half an hour, and every fifth slot is a long one, so 100 slots give exactly
    /// the 20 long paragraphs the gate asks for.
    static func plan(count: Int = defaultCount) -> [Slot] {
        let pattern: [Style] = [
            .work, .email, .chat, .notes, .work, .email, .chat, .notes, .work, .email,
            .chat, .notes, .work, .email, .chat, .notes, .work, .email, .chat, .work,
        ]
        return (0..<count).map { index in
            Slot(id: String(format: "p-%03d", index + 1), style: pattern[index % pattern.count],
                 isLong: (index + 1) % longEvery == 0)
        }
    }

    static func render(slots: [Slot], product: String) -> String {
        var lines: [String] = [
            "# Head-to-head dictation — \(product)",
            "",
            "<!-- One slot per paragraph. Put the cursor on the empty line under a heading, dictate",
            "     with \(product), and leave whatever it pasted exactly as it came out — no edits, no",
            "     retries unless the take was unusable (then re-dictate the whole slot). Say the same",
            "     paragraph, in the same words as best you can, into the other product's copy. Slots",
            "     marked LONG must run over 60 seconds of continuous speech. Keep the `## p-NNN` headings",
            "     unchanged: `murmur-eval head-to-head build` matches slots by that id. -->",
            "",
        ]
        for slot in slots {
            let length = slot.isLong ? "LONG (over 60 s)" : "short (10–40 s)"
            lines.append("## \(slot.id) · \(slot.style.rawValue) · \(length)")
            lines.append("<!-- \(slot.style.cue) -->")
            lines.append("")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing filled-in copies

    struct Parsed: Equatable, Sendable {
        /// Slot id -> dictated text (trimmed). Empty slots are omitted.
        let outputs: [String: String]
        let emptySlots: [String]
    }

    /// Reads a filled-in template: a `## <id>` heading starts a slot, everything until the next
    /// heading is its output, and HTML comments (the cues) are ignored. Tolerates the founder
    /// leaving blank lines or the product inserting a trailing newline.
    static func parse(_ text: String) -> Parsed {
        var outputs: [String: String] = [:]
        var empty: [String] = []
        var currentID: String?
        var buffer: [String] = []
        func flush() {
            guard let id = currentID else { return }
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { empty.append(id) } else { outputs[id] = body }
        }
        let stripped = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        for rawLine in stripped.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("## ") {
                flush()
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                currentID = heading.split(whereSeparator: { $0 == " " || $0 == "·" }).first.map(String.init)
                buffer = []
            } else if currentID != nil {
                buffer.append(line)
            }
        }
        flush()
        return Parsed(outputs: outputs, emptySlots: empty)
    }

    struct BuildResult: Equatable, Sendable {
        let pairs: [HeadToHeadPair]
        let missingHushy: [String]
        let missingOther: [String]
    }

    /// Joins the two parsed copies on slot id. A slot filled on only one side is reported, not
    /// paired, so a half-finished session still produces a usable (smaller) pairs file.
    static func build(hushy: Parsed, other: Parsed, otherName: String, audioDirectory: URL? = nil) -> BuildResult {
        let ids = Set(hushy.outputs.keys).union(other.outputs.keys).sorted()
        var pairs: [HeadToHeadPair] = []
        var missingHushy: [String] = [], missingOther: [String] = []
        for id in ids {
            guard let hushyText = hushy.outputs[id] else { missingHushy.append(id); continue }
            guard let otherText = other.outputs[id] else { missingOther.append(id); continue }
            pairs.append(HeadToHeadPair(
                id: id, audioPath: audioPath(for: id, in: audioDirectory),
                hushyOutput: hushyText, otherOutput: otherText, otherName: otherName))
        }
        return BuildResult(pairs: pairs, missingHushy: missingHushy, missingOther: missingOther)
    }

    private static func audioPath(for id: String, in directory: URL?) -> String? {
        guard let directory else { return nil }
        for ext in ["wav", "m4a", "caf", "mp3"] {
            let url = directory.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        return nil
    }
}
