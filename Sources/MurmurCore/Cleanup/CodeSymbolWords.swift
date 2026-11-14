import Foundation

/// The closed word lists behind `CodeSymbolGrammar`, `CodeFlags` and `CodeComments`. Each list is a
/// grammatical class (determiners, pronouns) or a short table of well-known command-line spellings,
/// never a list of sentences. A symbol word that sits next to one of these words is being used as
/// ordinary speech ("add a comma after the name", "a dash of salt"), so it stays a word.
enum CodeSymbolWords {
    /// Determiners and quantifiers: a symbol word right after one of these is a noun ("the colon",
    /// "a quote", "an open bracket"), not a symbol.
    static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "its",
        "his", "her", "another", "each", "every", "any", "no",
    ]

    /// Words that, right before a symbol word, make it the thing being talked about ("add comma",
    /// "missing semicolon", "double colon", "a single quote"). Includes the determiners.
    static let nounLeaders: Set<String> = determiners.union([
        "extra", "missing", "trailing", "leading", "stray", "unmatched", "add", "insert", "put",
        "type", "press", "remove", "delete", "drop", "need", "needs", "without", "double", "triple",
        "single", "forward", "back",
    ])

    /// Words right after a symbol word that show it is a noun ("comma separated", "colon placement").
    static let nounFollowers: Set<String> = [
        "separated", "delimited", "splice", "splices", "operator", "separator", "key", "character",
        "symbol", "placement", "style", "rule", "after", "before", "instead", "here", "there",
        "is", "was", "on", "at", "mismatch",
    ]

    /// A declaration qualifier before "double equals" means "double" is a type or name ("const double
    /// equals ..."), because `const ==` is never code; the "equals" alone is then the assignment.
    static let declarationQualifiers: Set<String> = [
        "const", "let", "var", "val", "final", "static", "mut", "private", "public", "readonly",
    ]

    /// Subject-like words: "it equals zero", "which equals" are statements about a value, not an
    /// assignment, so there is no left operand to assign to.
    static let statementSubjects: Set<String> = [
        "it", "that", "which", "he", "she", "they", "who", "there", "what", "and", "or", "but",
    ]

    /// After "equals" these start a noun phrase ("equals the total"): prose, not an assignment.
    static let proseObjectLeaders: Set<String> = [
        "the", "a", "an", "these", "those", "its", "their", "my", "your", "our", "his", "her", "some", "both",
    ]

    /// Function words that can never name a flag, a path part or an identifier piece.
    static let functionWords: Set<String> = determiners.union([
        "of", "and", "or", "to", "is", "are", "was", "be", "it", "in", "on", "at", "for", "with",
        "how", "why", "what", "when", "if", "then", "so", "not",
    ])

    /// Words before "underscore" that make it the verb ("we should underscore the point").
    static let underscoreVerbLeaders: Set<String> = [
        "to", "will", "would", "can", "could", "should", "must", "might", "may", "shall", "and", "or",
        "we", "i", "you", "they", "it", "also", "please", "then", "just", "that", "which", "who",
        "let's", "don't", "doesn't",
    ]

    static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// A single digit word followed by one of these is a quantity ("equals five minutes").
    static let unitWords: Set<String> = [
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "time", "times", "percent", "ms", "milliseconds", "people",
        "items", "users", "bytes", "lines", "files", "retries", "attempts",
    ]

    /// After "fat arrow" these show it is the name of a syntax ("fat arrow functions").
    static let fatArrowFollowers: Set<String> = [
        "function", "functions", "syntax", "notation", "operator", "operators", "lambda", "lambdas",
    ]

    /// After a starting "hash" these make it the noun "hash map", not a comment marker.
    static let hashNounFollowers: Set<String> = [
        "map", "maps", "table", "tables", "tag", "tags", "sign", "symbol", "key", "keys", "function",
        "functions", "code", "value", "values", "set", "algorithm", "collision", "collisions", "join",
        "rate", "sum", "bang", "of", "it", "out", "tree",
    ]

    /// After a starting "hash" these make it the verb ("hash the password"), never a comment marker.
    /// A missed marker leaves a visible word the writer fixes at once; "#" would silently delete the
    /// verb from an agent prompt. Known limit: a comment such as "hash the input here" stays words.
    static let hashVerbObjectLeaders: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "our", "your", "their", "its", "it",
    ]

    /// Well-known multi-word long options ("dash dash save dev" is `--save-dev`). A closed table of
    /// spellings from git, npm, docker and kubectl; any other `dash dash word` is a one-word flag.
    static let longFlagCompounds: [[String]] = [
        ["force", "with", "lease"], ["save", "dev"], ["save", "exact"], ["save", "optional"],
        ["dry", "run"], ["no", "verify"], ["no", "cache"], ["no", "color"], ["no", "edit"],
        ["no", "commit"], ["no", "pager"], ["no", "install"], ["no", "deps"], ["no", "ff"],
        ["ff", "only"], ["set", "upstream"], ["name", "only"], ["max", "count"], ["ignore", "scripts"],
        ["follow", "tags"], ["fail", "fast"], ["all", "namespaces"], ["include", "untracked"],
        ["keep", "index"], ["no", "stream"], ["no", "trunc"],
    ].sorted { $0.count > $1.count }
}
