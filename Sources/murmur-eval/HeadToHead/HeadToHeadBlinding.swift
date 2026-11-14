import Foundation

/// Which side of a blinded pair a voter or judge preferred.
enum BlindChoice: String, Codable, Equatable, Sendable {
    case a = "A"
    case b = "B"
    case tie
}

/// The same choice after unblinding: expressed in terms of the real products.
enum Preference: String, Codable, Equatable, Sendable {
    case hushy
    case other
    case tie
}

/// A pair with its two outputs relabelled A/B in a seeded-random order. Everything a reviewer
/// or the judge sees comes from this struct's `a`/`b`; `hushyIsA` is the unblinding key and is
/// only ever written to the report, never to the review form or the judge prompt.
struct BlindedPair: Equatable, Sendable {
    let id: String
    let a: String
    let b: String
    let hushyIsA: Bool

    func unblind(_ choice: BlindChoice) -> Preference {
        switch choice {
        case .tie: .tie
        case .a: hushyIsA ? .hushy : .other
        case .b: hushyIsA ? .other : .hushy
        }
    }
}

/// Seeding uses `SeededGenerator` (SplitMix64, declared in StreamingRunner.swift): a run with
/// `--seed N` produces the same A/B assignment on every machine and every Swift version.
enum HeadToHeadBlinding {
    static let defaultSeed: UInt64 = 42

    /// Flips a seeded coin per pair for the A/B order, then shuffles the pair order with the
    /// same generator so neither position nor sequence leaks which side is Hushy. Deterministic
    /// for a given (pairs, seed): the review form and the judge run see the same assignment, and
    /// votes collected days later still unblind correctly.
    static func blind(_ pairs: [HeadToHeadPair], seed: UInt64 = defaultSeed) -> [BlindedPair] {
        var generator = SeededGenerator(seed: seed)
        let blinded = pairs.map { pair -> BlindedPair in
            let hushyIsA = Bool.random(using: &generator)
            return BlindedPair(
                id: pair.id,
                a: hushyIsA ? pair.hushyOutput : pair.otherOutput,
                b: hushyIsA ? pair.otherOutput : pair.hushyOutput,
                hushyIsA: hushyIsA)
        }
        return blinded.shuffled(using: &generator)
    }
}
