import Foundation

/// Port of Whisper's `EnglishNumberNormalizer` (`whisper/normalizers/english.py`, MIT License,
/// Copyright (c) 2022 OpenAI): spelled-out numbers become digits ("twenty three" → "23",
/// "one oh one" → "101", "five dollars" → "$5", "ten percent" → "10%"), keeping suffixes
/// ("1960s", "32nd"). Branch order and quirks follow the original exactly — including that
/// "ninth" is not recognised (the original builds "nineth") — because the point is agreement with
/// published numbers, not better normalisation. See `WhisperEnglishNormalizer` for the caveats.
enum WhisperNumberNormalizer {
    static func normalize(_ s: String) -> String {
        let words = preprocess(s).split(whereSeparator: \.isWhitespace).map(String.init)
        return postprocess(processWords(words).joined(separator: " "))
    }

    // MARK: Vocabulary

    static let zeros: Set<String> = ["o", "oh", "zero"]
    static let onesNames = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    static let ones: [String: Int] = Dictionary(uniqueKeysWithValues: onesNames.enumerated().map { ($1, $0 + 1) })
    static let onesSuffixed: [String: (Int, String)] = {
        var map: [String: (Int, String)] = [:]
        for (name, value) in ones { map[name == "six" ? "sixes" : name + "s"] = (value, "s") }
        let fixed: [(String, Int, String)] = [
            ("zeroth", 0, "th"), ("first", 1, "st"), ("second", 2, "nd"), ("third", 3, "rd"),
            ("fifth", 5, "th"), ("twelfth", 12, "th"),
        ]
        for (name, value, suffix) in fixed { map[name] = (value, suffix) }
        for (name, value) in ones where value > 3 && value != 5 && value != 12 {
            map[name + (name.hasSuffix("t") ? "h" : "th")] = (value, "th")
        }
        return map
    }()
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let tensSuffixed: [String: (Int, String)] = {
        var map: [String: (Int, String)] = [:]
        for (name, value) in tens {
            map[name.replacingOccurrences(of: "y", with: "ies")] = (value, "s")
            map[name.replacingOccurrences(of: "y", with: "ieth")] = (value, "th")
        }
        return map
    }()
    static let multipliers: [String: Decimal] = {
        let names = ["hundred", "thousand", "million", "billion", "trillion", "quadrillion", "quintillion",
                     "sextillion", "septillion", "octillion", "nonillion", "decillion"]
        var map: [String: Decimal] = ["hundred": 100]
        var value = Decimal(1000)
        for name in names.dropFirst() {
            map[name] = value
            value *= 1000
        }
        return map
    }()
    static let multipliersSuffixed: [String: (Decimal, String)] = {
        var map: [String: (Decimal, String)] = [:]
        for (name, value) in multipliers {
            map[name + "s"] = (value, "s")
            map[name + "th"] = (value, "th")
        }
        return map
    }()
    static let decimals: Set<String> = Set(ones.keys).union(tens.keys).union(zeros)
    static let precedingPrefixers = ["minus": "-", "negative": "-", "plus": "+", "positive": "+"]
    static let followingPrefixers = [
        "pound": "£", "pounds": "£", "euro": "€", "euros": "€", "dollar": "$", "dollars": "$", "cent": "¢", "cents": "¢",
    ]
    static let prefixes: Set<String> = Set(precedingPrefixers.values).union(followingPrefixers.values)
    static let suffixers: Set<String> = ["per", "percent"]
    static let specials: Set<String> = ["and", "double", "triple", "point"]
    static let words: Set<String> = zeros.union(ones.keys).union(onesSuffixed.keys).union(tens.keys)
        .union(tensSuffixed.keys).union(multipliers.keys).union(multipliersSuffixed.keys)
        .union(precedingPrefixers.keys).union(followingPrefixers.keys).union(suffixers).union(specials)

    static let numeric = PyRegex(#"^\d+(\.\d+)?$"#)
    private static let pythonFraction = PyRegex(#"^\s*[-+]?(?=\d|\.\d)\d*(\.\d*)?\s*$"#)

    // MARK: Values (the original's `value: Optional[Union[str, int]]`)

    enum Value: Equatable {
        case int(Int)
        case text(String)

        var string: String {
            switch self {
            case .int(let number): String(number)
            case .text(let text): text
            }
        }
    }

    /// Python's `str(value or "")`: empty for no value and for the integer 0.
    static func orEmpty(_ value: Value?) -> String {
        guard let value, value != .int(0) else { return "" }
        return value.string
    }

    /// `Fraction(s)` for the digit/period strings this normaliser produces; nil where Python raises.
    static func fraction(_ s: String) -> Decimal? {
        guard pythonFraction.matches(s) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-")
        let body = trimmed.drop { $0 == "-" || $0 == "+" }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        let fractional = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : "0"
        guard let value = Decimal(string: "\(whole).\(fractional)", locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return negative ? -value : value
    }

    /// An integral `Decimal` as `.int`, or nil when it has a fractional part.
    static func integral(_ value: Decimal) -> Value? {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == value else { return nil }
        let digits = NSDecimalNumber(decimal: rounded).stringValue
        return Int(digits).map(Value.int) ?? .text(digits)
    }

    // MARK: preprocess / postprocess

    private static let andAHalf = PyRegex(#"\band\s+a\s+half\b"#)
    private static let letterDigit = PyRegex(#"([a-z])([0-9])"#)
    private static let digitLetter = PyRegex(#"([0-9])([a-z])"#)
    private static let digitSuffix = PyRegex(#"([0-9])\s+(st|nd|rd|th|s)\b"#)
    private static let combineCents = PyRegex(#"([€£$])([0-9]+) (?:and )?¢([0-9]{1,2})\b"#)
    private static let extractCents = PyRegex(#"[€£$]0.([0-9]{1,2})\b"#)
    private static let standaloneOne = PyRegex(#"(?<!\S)1(s?)(?!\S)"#)

    static func preprocess(_ input: String) -> String {
        // "<number> and a half" → "<number> point five"
        let segments = andAHalf.split(input)
        var results: [String] = []
        for (index, segment) in segments.enumerated() {
            if segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            results.append(segment)
            guard index < segments.count - 1 else { continue }
            let lastWord = segment.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            results.append(decimals.contains(lastWord) || multipliers[lastWord] != nil ? "point five" : "and a half")
        }
        var s = results.joined(separator: " ")
        s = letterDigit.replace(s, with: "$1 $2")
        s = digitLetter.replace(s, with: "$1 $2")
        return digitSuffix.replace(s, with: "$1$2")
    }

    static func postprocess(_ input: String) -> String {
        var s = combineCents.replace(input) { groups in
            let cents = Int(groups[3]) ?? 0
            return "\(groups[1])\(groups[2]).\(cents < 10 ? "0" : "")\(cents)"
        }
        s = extractCents.replace(s) { groups in "¢\(Int(groups[1]) ?? 0)" }
        return standaloneOne.replace(s, with: "one$1")
    }

    // MARK: process_words

    static func processWords(_ words: [String]) -> [String] {
        var state = State()
        guard !words.isEmpty else { return [] }
        let padded: [String?] = [nil] + words.map { Optional($0) } + [nil]
        for index in 1...words.count {
            if state.skip {
                state.skip = false
                continue
            }
            state.step(prev: padded[index - 1], current: words[index - 1], next: padded[index + 1])
        }
        if let value = state.value { state.emit(value.string) }
        return state.out
    }
}
