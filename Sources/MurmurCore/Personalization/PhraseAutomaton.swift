import Foundation

/// How a Unicode scalar is compared and classified when Dictionary phrases are matched.
///
/// The Dictionary used to be applied with one case-insensitive `NSRegularExpression` per heard phrase, wrapped in
/// `(?<![\w])…(?![\w])`. The matching automaton has to agree with that on every scalar, so both questions the regex answers
/// are answered here: which scalars count as the same letter, and which scalars are word characters.
enum PhraseFolding {
    /// The symbol a scalar is compared as: its lower case for ASCII and for every scalar whose case mapping is one-to-one.
    /// Nil for the scalars where ICU's case-insensitive matching is not a plain one-to-one fold (ß and "ss", the dotted İ,
    /// final sigma, ligatures). Text or a heard phrase holding one is handed to the regular-expression path instead.
    static func symbol(_ scalar: Unicode.Scalar) -> UInt32? {
        let value = scalar.value
        if value < 128 { return value >= 65 && value <= 90 ? value + 32 : value }
        if value == 0x1E9E { return nil }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        let upper = scalar.properties.uppercaseMapping.unicodeScalars
        guard lower.count == 1, upper.count == 1, let lowered = lower.first, let raised = upper.first else { return nil }
        let back = raised.properties.lowercaseMapping.unicodeScalars
        guard back.count == 1, back.first == lowered else { return nil }
        return lowered.value
    }

    /// ICU's `\w`: `[\p{Alphabetic}\p{Mark}\p{Decimal_Number}\p{Connector_Punctuation}‌‍]`.
    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 {
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || value == 95
        }
        let properties = scalar.properties
        if properties.isAlphabetic || value == 0x200C || value == 0x200D { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }
}

/// Aho–Corasick automaton (Aho and Corasick, 1975) over folded Unicode scalars: every pattern is found in one left-to-right
/// pass over the text.
///
/// - Build: O(total pattern length) trie nodes, failure links in breadth-first order.
/// - Scan: O(text length + occurrences), independent of how many patterns there are.
///
/// Pattern `i` is reported as `emit(i, endExclusive)`; its start is `endExclusive - patternLengths[i]`. Patterns that are the
/// same string are reported in pattern order.
struct PhraseAutomaton: Sendable {
    private let edges: [UInt64: Int32]
    private let rootEdges: [Int32]
    private let failure: [Int32]
    private let suffixOutput: [Int32]
    private let outputStart: [Int32]
    private let outputRules: [Int32]
    let patternLengths: [Int32]

    init(patterns: [[UInt32]]) {
        var edges: [UInt64: Int32] = [:]
        var parent: [Int32] = [-1]
        var symbol: [UInt32] = [0]
        var depth: [Int32] = [0]
        var terminals: [(node: Int32, rule: Int32)] = []
        for (rule, pattern) in patterns.enumerated() {
            var node: Int32 = 0
            for value in pattern {
                let key = Self.key(node, value)
                if let child = edges[key] { node = child; continue }
                let child = Int32(parent.count)
                parent.append(node)
                symbol.append(value)
                depth.append(depth[Int(node)] + 1)
                edges[key] = child
                node = child
            }
            terminals.append((node, Int32(rule)))
        }
        let nodeCount = parent.count
        var failure = [Int32](repeating: 0, count: nodeCount)
        var suffixOutput = [Int32](repeating: 0, count: nodeCount)
        let (outputStart, outputRules) = Self.outputTable(terminals, nodeCount: nodeCount)
        for node in Self.breadthFirstOrder(depth) {
            let up = Int(parent[node])
            if up > 0 {
                var candidate = failure[up]
                while true {
                    if let next = edges[Self.key(candidate, symbol[node])] { failure[node] = next; break }
                    if candidate == 0 { break }
                    candidate = failure[Int(candidate)]
                }
            }
            let fallback = Int(failure[node])
            suffixOutput[node] = outputStart[fallback + 1] > outputStart[fallback] ? Int32(fallback) : suffixOutput[fallback]
        }
        self.edges = edges
        self.rootEdges = (0..<128).map { edges[Self.key(0, UInt32($0))] ?? 0 }
        self.failure = failure
        self.suffixOutput = suffixOutput
        self.outputStart = outputStart
        self.outputRules = outputRules
        self.patternLengths = patterns.map { Int32($0.count) }
    }

    var isEmpty: Bool { patternLengths.isEmpty }

    func scan(_ symbols: [UInt32], emit: (_ pattern: Int, _ endExclusive: Int) -> Void) {
        var state: Int32 = 0
        for (position, value) in symbols.enumerated() {
            state = step(state, value)
            var node = outputStart[Int(state) + 1] > outputStart[Int(state)] ? state : suffixOutput[Int(state)]
            while node != 0 {
                for slot in Int(outputStart[Int(node)])..<Int(outputStart[Int(node) + 1]) {
                    emit(Int(outputRules[slot]), position + 1)
                }
                node = suffixOutput[Int(node)]
            }
        }
    }

    private func step(_ state: Int32, _ value: UInt32) -> Int32 {
        var current = state
        while true {
            if current == 0 { return value < 128 ? rootEdges[Int(value)] : (edges[Self.key(0, value)] ?? 0) }
            if let next = edges[Self.key(current, value)] { return next }
            current = failure[Int(current)]
        }
    }

    private static func key(_ node: Int32, _ value: UInt32) -> UInt64 { UInt64(UInt32(bitPattern: node)) << 32 | UInt64(value) }

    /// Nodes 1… ordered by depth, so a node's failure link is always computed after the shallower nodes it points to.
    private static func breadthFirstOrder(_ depth: [Int32]) -> [Int] {
        let maxDepth = Int(depth.max() ?? 0)
        var counts = [Int](repeating: 0, count: maxDepth + 2)
        for node in 1..<max(depth.count, 1) { counts[Int(depth[node]) + 1] += 1 }
        for level in 1..<counts.count { counts[level] += counts[level - 1] }
        var order = [Int](repeating: 0, count: max(depth.count - 1, 0))
        for node in 1..<max(depth.count, 1) {
            order[counts[Int(depth[node])]] = node
            counts[Int(depth[node])] += 1
        }
        return order
    }

    /// Compressed rows: the patterns that end exactly at each node, in pattern order.
    private static func outputTable(_ terminals: [(node: Int32, rule: Int32)], nodeCount: Int) -> ([Int32], [Int32]) {
        let sorted = terminals.sorted { ($0.node, $0.rule) < ($1.node, $1.rule) }
        var start = [Int32](repeating: 0, count: nodeCount + 1)
        for terminal in sorted { start[Int(terminal.node) + 1] += 1 }
        for node in 1...nodeCount { start[node] += start[node - 1] }
        return (start, sorted.map(\.rule))
    }
}
