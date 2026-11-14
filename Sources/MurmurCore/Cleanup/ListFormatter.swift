import Foundation

/// Turns spoken enumerations into Markdown-style lists.
///
/// Handles three shapes:
/// - Ordinals: "First, buy milk. Second, call mom." -> "1. Buy milk\n2. Call mom"
/// - Bullets: "bullet eggs bullet flour" -> "- Eggs\n- Flour"
/// - Introduced series: "Create a to-do list, tomatoes, onions, beans and ketchup." ->
///   "Create a to-do list:\n- Tomatoes\n- Onions\n- Beans\n- Ketchup"
enum ListFormatter {
    /// In a code context "dash" is a command-line flag word, never a bullet ("dash dash dash dash
    /// mode" must not become a list), so `codeContext` drops it from the bullet words.
    static func format(_ text: String, codeContext: Bool = false) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                formatOrdinals(line) ?? formatBullets(line, codeContext: codeContext)
                    ?? formatIntroducedSeries(line) ?? line
            }
            .joined(separator: "\n")
    }

    private static let ordinals = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    // MARK: Ordinals

    private static func formatOrdinals(_ line: String) -> String? {
        let words = ordinals.joined(separator: "|")
        // The comma/colon after the ordinal is required, not optional: "First, buy milk" is an
        // enumeration marker, but "the first half", "the second narrator" is an ordinal
        // modifying a noun mid-sentence and must never be mistaken for a list item — the same
        // distinction "My plan is first, fix the bug." (comma-marked, IS a list) vs "I read the
        // first chapter" (no comma, is NOT a list) makes for a human reader.
        let pattern = "(?:^|(?<=[.,;:!?])\\s+|\\s+(?:and\\s+)?)(?:\(words))(?:ly)?[,:]\\s+"
        let matches = Regex.matches(line, pattern)
        guard matches.count >= 2 else { return nil }

        // The ordinals must appear in order: first, second, third…
        let found = matches.compactMap { match -> String? in
            guard let range = Range(match.range, in: line) else { return nil }
            return line[range].lowercased().components(separatedBy: CharacterSet.letters.inverted)
                .first { ordinals.contains($0) || ordinals.contains($0.replacingOccurrences(of: "ly", with: "")) }
        }
        guard found.count <= ordinals.count, found.enumerated().allSatisfy({ index, word in
            word == ordinals[index] || word == ordinals[index] + "ly"
        }) else { return nil }

        let nsLine = line as NSString
        let intro = nsLine.substring(to: matches[0].range.location)
        var items: [String] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsLine.length
            let item = cleanItem(nsLine.substring(with: NSRange(location: start, length: end - start)))
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= 2 else { return nil }
        let body = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return join(intro: intro, body: body)
    }

    // MARK: Bullets

    private static func formatBullets(_ line: String, codeContext: Bool = false) -> String? {
        let words = codeContext ? "bullet|bullet point" : "bullet|bullet point|dash"
        let pattern = "(?:^|[.,;:]?\\s+)(?:\(words))[,:]?\\s+"
        let matches = Regex.matches(line, pattern)
        guard matches.count >= 2 else { return nil }
        let nsLine = line as NSString
        let intro = nsLine.substring(to: matches[0].range.location)
        var items: [String] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsLine.length
            let item = cleanItem(nsLine.substring(with: NSRange(location: start, length: end - start)))
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= 2 else { return nil }
        return join(intro: intro, body: items.map { "- \($0)" }.joined(separator: "\n"))
    }

    // MARK: Introduced series

    /// An explicit list intro ("shopping list,", "the list is:", "agenda for today,", "three
    /// things:") followed by the series. This is the "introduced list" signal of the list style
    /// contract (`ListStructureGuard`); a lead without one ("I need to get A, B and C") is an inline
    /// series and stays a sentence.
    private static let introPattern =
        "^(.*?\\b(?:list|the following|these(?: things| items)?|items|agenda|steps|groceries|to-?dos?|topics"
        + "|(?:\\d+|two|three|four|five|six|seven|eight|nine|ten)\\s+(?:things|points|tasks))\\b(?:\\s+\\w+){0,3}?)"
        + "\\s*(?:is|are|includes?)?\\s*[,:]\\s*(.+)$"

    /// A correction cue opening one of the series' comma parts (", no, …", ", actually …"). Not
    /// `ModelHints.correctionCues`: "cancel"/"drop"/"skip" are ordinary to-do verbs in a list.
    private static let correctionInSeries =
        "(?:^|[,.;]\\s*)(?:no|nope|actually|i mean|i meant|wait|sorry|scratch that|never ?mind|oops)\\b"

    private static func formatIntroducedSeries(_ line: String) -> String? {
        guard let match = Regex.firstMatch(line, introPattern),
              let intro = match.string(at: 1, in: line),
              let series = match.string(at: 2, in: line)
        else { return nil }

        // A correction still unresolved inside the series ("three things, a logo, a landing page,
        // no, actually two things, …") is not a list yet: leave it for the model.
        guard Regex.firstMatch(series, correctionInSeries) == nil else { return nil }
        let items = splitSeries(series)
        guard items.count >= 3, items.allSatisfy({ Token.split($0).count <= 5 }) else { return nil }
        return intro.trimmingCharacters(in: .whitespaces) + ":\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func splitSeries(_ series: String) -> [String] {
        let trimmed = Punctuation.stripTrailing(series)
        let parts = trimmed.components(separatedBy: ",")
        var items: [String] = []
        for (index, part) in parts.enumerated() {
            var item = part.trimmingCharacters(in: .whitespaces)
            if index == parts.count - 1 {
                item = Regex.replace(item, "^(?:and|or)\\s+", with: "")
            }
            if index == parts.count - 1, parts.count == 1 { break }
            // "beans and ketchup" as the last element splits into two items.
            if index == parts.count - 1, let match = Regex.firstMatch(item, "^(.+?)\\s+and\\s+(.+)$"),
               let left = match.string(at: 1, in: item), let right = match.string(at: 2, in: item) {
                items.append(cleanItem(left))
                items.append(cleanItem(right))
                continue
            }
            let cleaned = cleanItem(item)
            if !cleaned.isEmpty { items.append(cleaned) }
        }
        return items
    }

    /// Models sometimes return "We need: - A - B - C" on one line; put each item on its own line.
    ///
    /// Guarded against a real failure mode: a spoken decimal, version or clock time read as
    /// "point"/"colon"-separated digits ("version two: point three point one") looks exactly
    /// like this shape to a naive split, and the model has turned it into a bogus list before
    /// ("version two: - Point three - Point one"). Items that are each just "Point <number>" —
    /// the fragments a mis-split decimal/version leaves behind — are never treated as a real
    /// enumeration.
    public static func splitInlineBullets(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            guard let match = Regex.firstMatch(line, "^(.*?):\\s*[-•]\\s+(.+)$"),
                  let lead = match.string(at: 1, in: line), let rest = match.string(at: 2, in: line)
            else { return line }
            let items = rest.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard items.count >= 2, !looksLikePointSequence(lead: lead, items: items) else { return line }
            return lead + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// True when every item is a bare "Point <number>" fragment, or the lead ends in a number —
    /// the shape left behind when a spoken decimal or version reading ("two point three point
    /// one") is mis-split on its own "point"s rather than converted to digits.
    private static func looksLikePointSequence(lead: String, items: [String]) -> Bool {
        let allPointFragments = items.allSatisfy { Regex.firstMatch($0, "^point\\s+\\S+$") != nil }
        guard allPointFragments else { return false }
        return Regex.firstMatch(lead, "\\b(?:\\d+|\(InverseTextNormalizer.ones.keys.joined(separator: "|"))|\(InverseTextNormalizer.teens.keys.joined(separator: "|")))\\s*$") != nil
    }

    // MARK: Helpers

    private static func cleanItem(_ raw: String) -> String {
        var item = raw.trimmingCharacters(in: .whitespaces)
        item = Regex.replace(item, "^(?:and|then|also)\\s+", with: "")
        item = Punctuation.stripTrailing(item)
        guard let first = item.first else { return "" }
        return first.uppercased() + item.dropFirst()
    }

    private static func join(intro: String, body: String) -> String {
        let lead = Punctuation.stripTrailing(intro.trimmingCharacters(in: .whitespaces))
        return lead.isEmpty ? body : lead + ":\n" + body
    }
}
