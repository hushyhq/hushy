import Foundation

/// Percentiles ("p 99" -> "p99") and cloud regions ("us east one" -> "us-east-1"). Part of
/// `SpokenTechnicalTokens`. Both need the sentence to be about latency or infrastructure, because
/// "p" and "us east" are ordinary speech too.
enum SpokenMetricTokens {
    static func apply(_ text: String) -> String {
        TokenRewrite.replace(
            TokenRewrite.replace(text, pattern: percentilePattern, percentile), pattern: regionPattern, region)
    }

    // MARK: Percentiles

    private static let percentilePattern = #"(?<![\w.#-])p\s+(\d{2,4}(?:\.\d{1,2})?)(?!\d|\s?%|\.\d)\b"#

    private static let percentileValues: Set<String> = ["50", "75", "90", "95", "99", "99.9", "99.99", "999", "9999"]

    private static let latencyWords: Set<String> = [
        "latency", "latencies", "response", "responses", "tail", "percentile", "percentiles", "ms",
        "millisecond", "milliseconds", "second", "seconds", "spike", "spiked", "spikes", "slow", "slower",
        "slowest", "regression", "regressed", "duration", "throughput", "jitter", "timeout", "timeouts",
    ]

    private static let possessives: Set<String> = ["the", "our", "your", "my", "their", "its"]

    /// "p 99 on the search call", "p 95 at peak", "p 99 by region": a percentile is followed by a
    /// preposition as often as not. The number-quantity check skips these three, which
    /// `TokenLexicon.quantityWords` holds for "5 at a time"; "p 99 days" stays a quantity.
    private static let prepositionsAfterPercentile: Set<String> = ["at", "on", "by"]

    /// How close the evidence has to be: the words right around "p 99", not the whole sentence.
    private static let wordsBeforeWindow = 4
    private static let wordsAfterWindow = 6

    /// A numbered thing, or a survey/form word, directly before the "p": "question p 95", "on the
    /// survey p 99". The "p" is a label or an answer choice there, whatever else the sentence says.
    private static let numberedItems: Set<String> = [
        "question", "questions", "item", "items", "option", "options", "plan", "plans", "part", "section",
        "step", "page", "problem", "exercise", "chapter", "row", "column", "slide", "paragraph", "clause",
        "tier", "group", "survey", "form", "quiz", "exam", "poll", "questionnaire", "answer", "choice",
    ]

    /// What a percentile does, directly after it: "p 95 doubled". A closed set of change verbs.
    private static let trendVerbs: Set<String> = [
        "doubled", "tripled", "halved", "spiked", "dropped", "regressed", "improved", "climbed", "jumped",
        "rose", "fell", "increased", "decreased", "grew", "worsened", "recovered", "flatlined", "crept",
    ]

    /// How a metric is doing, within a few words after it: "p 95 looks flat", "p 95 is back to normal".
    private static let stateWords: Set<String> = [
        "flat", "stable", "steady", "normal", "high", "higher", "low", "lower", "up", "down", "elevated",
        "spiking", "climbing", "rising", "falling", "creeping", "recovering",
    ]

    private static func percentile(_ match: TokenMatch) -> String? {
        guard let value = match.group(1), percentileValues.contains(value) else { return nil }
        let after = match.wordsAfter(wordsAfterWindow)
        if let next = after.first, TokenLexicon.quantityWords.contains(next),
           !prepositionsAfterPercentile.contains(next) { return nil }
        let before = match.wordsBefore(wordsBeforeWindow)
        if before.suffix(2).contains(where: numberedItems.contains) { return nil }
        let aboutLatency = !latencyWords.isDisjoint(with: before + after)
        let namedMetric = before.last.map(possessives.contains) ?? false
        let trending = after.first.map(trendVerbs.contains) ?? false || !stateWords.isDisjoint(with: after.prefix(4))
        guard aboutLatency || namedMetric || trending else { return nil }
        return "p" + value
    }

    // MARK: Regions

    private static let directions = "northeast|northwest|southeast|southwest|north|south|east|west|central"
    private static let regionPattern =
        #"(?<![\w-])(us|eu|ap|sa|af|ca)\s+("# + directions + #")\s+(\d|one|two|three|four|five|six|seven|eight|nine)(?![\w.]|\s?%)"#

    private static let prepositions: Set<String> = ["in", "to", "from", "into", "across", "between", "via", "on", "at", "within", "onto"]

    private static let infrastructureWords: Set<String> = [
        "region", "regions", "cluster", "clusters", "bucket", "buckets", "deploy", "deployed", "deploying",
        "deployment", "failover", "failed", "traffic", "replica", "replicas", "instance", "instances",
        "server", "servers", "datacenter", "aws", "gcp", "azure", "s3", "ec2", "lambda", "outage", "cloud",
        "availability", "zone", "zones", "rds", "queue", "database", "pods", "node", "nodes", "stack", "vpc",
        "endpoint", "endpoints", "latency", "shifted", "routing", "routed", "migrate", "migrated", "provisioned",
    ]

    private static let digitValues = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static func region(_ match: TokenMatch) -> String? {
        guard let prefix = match.group(1), let direction = match.group(2), let number = match.group(3) else { return nil }
        guard let before = match.wordsBefore(1).first, prepositions.contains(before) else { return nil }
        if let next = match.wordsAfter(1).first, TokenLexicon.quantityWords.contains(next) { return nil }
        let sentence = match.wordsBefore(40) + match.wordsAfter(40)
        guard !infrastructureWords.isDisjoint(with: sentence) else { return nil }
        let digit = digitValues[number.lowercased()] ?? number
        return "\(prefix.lowercased())-\(direction.lowercased())-\(digit)"
    }
}
