import Foundation

/// A port of NLTK's `TreebankWordTokenizer.tokenize` (nltk/tokenize/treebank.py, Apache-2.0,
/// `convert_parentheses=False`) — the tokenizer DRES applies to model output before alignment.
/// The substitution lists are NLTK's, in NLTK's order, including the MacIntyre contractions
/// ("cannot" → "can not", "gonna" → "gon na").
///
/// Python `re` and ICU agree on every construct used here (`\d`, `\s`, `\b`, `(?i)`,
/// lookahead); the only syntax change is `\g<0>` → `$0` and `\1` → `$1` in templates.
enum TreebankWordTokenizer {
    private typealias Rule = (PyRegex, String)

    private static let startingQuotes: [Rule] = [
        (PyRegex(#"^\""#), "``"),
        (PyRegex(#"(``)"#), " $1 "),
        (PyRegex(#"([ \(\[{<])(\"|'{2})"#), "$1 `` "),
    ]

    private static let punctuation: [Rule] = [
        (PyRegex(#"([:,])([^\d])"#), " $1 $2"),
        (PyRegex(#"([:,])$"#), " $1 "),
        (PyRegex(#"\.\.\."#), " ... "),
        (PyRegex(#"[;@#\$%&]"#), " $0 "),
        (PyRegex(#"([^\.])(\.)([\]\)}>"']*)\s*$"#), "$1 $2$3 "),
        (PyRegex(#"[?!]"#), " $0 "),
        (PyRegex(#"([^'])' "#), "$1 ' "),
    ]

    private static let parensBrackets: Rule = (PyRegex(#"[\]\[\(\)\{\}<>]"#), " $0 ")
    private static let doubleDashes: Rule = (PyRegex(#"--"#), " -- ")

    private static let endingQuotes: [Rule] = [
        (PyRegex(#"''"#), " '' "),
        (PyRegex(#"""#), " '' "),
        (PyRegex(#"([^' ])('[sS]|'[mM]|'[dD]|') "#), "$1 $2 "),
        (PyRegex(#"([^' ])('ll|'LL|'re|'RE|'ve|'VE|n't|N'T) "#), "$1 $2 "),
    ]

    private static let contractions2: [PyRegex] = [
        #"(?i)\b(can)(not)\b"#, #"(?i)\b(d)('ye)\b"#, #"(?i)\b(gim)(me)\b"#, #"(?i)\b(gon)(na)\b"#,
        #"(?i)\b(got)(ta)\b"#, #"(?i)\b(lem)(me)\b"#, #"(?i)\b(more)('n)\b"#, #"(?i)\b(wan)(na)(?=\s)"#,
    ].map(PyRegex.init)

    private static let contractions3: [PyRegex] = [#"(?i) ('t)(is)\b"#, #"(?i) ('t)(was)\b"#].map(PyRegex.init)

    static func tokenize(_ input: String) -> [String] {
        var text = input
        for (regex, template) in startingQuotes { text = regex.replace(text, with: template) }
        for (regex, template) in punctuation { text = regex.replace(text, with: template) }
        text = parensBrackets.0.replace(text, with: parensBrackets.1)
        text = doubleDashes.0.replace(text, with: doubleDashes.1)
        text = " " + text + " "
        for (regex, template) in endingQuotes { text = regex.replace(text, with: template) }
        for regex in contractions2 { text = regex.replace(text, with: " $1 $2 ") }
        for regex in contractions3 { text = regex.replace(text, with: " $1 $2 ") }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
