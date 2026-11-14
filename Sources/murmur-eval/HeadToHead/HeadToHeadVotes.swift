import Foundation

/// One human reviewer's blind votes, as saved by the review form (`HeadToHeadReviewForm`). The
/// form only ever writes `A`/`B`/`tie` per pair id plus the seed it was generated with; the
/// seed is what lets `murmur-eval head-to-head --votes` re-derive the blinding and unblind.
struct HeadToHeadVoteFile: Codable, Equatable, Sendable {
    let reviewer: String
    let seed: UInt64
    let votes: [Vote]

    struct Vote: Codable, Equatable, Sendable {
        let id: String
        let choice: BlindChoice
    }
}

enum HeadToHeadVotes {
    enum LoadError: LocalizedError, Equatable {
        case seedMismatch(file: String, fileSeed: UInt64, runSeed: UInt64)
        case unknownPair(file: String, id: String)

        var errorDescription: String? {
            switch self {
            case .seedMismatch(let file, let fileSeed, let runSeed):
                "\(file) was voted with --seed \(fileSeed) but this run uses --seed \(runSeed); rerun with the same seed to unblind it"
            case .unknownPair(let file, let id):
                "\(file) votes on pair \(id), which is not in the pairs file"
            }
        }
    }

    struct Unblinded: Equatable, Sendable {
        let reviewer: String
        /// Pair id -> preference, only for pairs the reviewer actually voted on.
        let preferences: [String: Preference]
    }

    static func load(from url: URL) throws -> HeadToHeadVoteFile {
        try JSONDecoder().decode(HeadToHeadVoteFile.self, from: Data(contentsOf: url))
    }

    /// Unblinds one vote file against the run's blinded pairs. A seed mismatch is an error, not
    /// a warning: unblinding with the wrong seed silently produces plausible-looking nonsense.
    static func unblind(_ file: HeadToHeadVoteFile, fileName: String, blinded: [BlindedPair], seed: UInt64) throws -> Unblinded {
        guard file.seed == seed else {
            throw LoadError.seedMismatch(file: fileName, fileSeed: file.seed, runSeed: seed)
        }
        let byID = Dictionary(uniqueKeysWithValues: blinded.map { ($0.id, $0) })
        var preferences: [String: Preference] = [:]
        for vote in file.votes {
            guard let pair = byID[vote.id] else { throw LoadError.unknownPair(file: fileName, id: vote.id) }
            preferences[vote.id] = pair.unblind(vote.choice)
        }
        return Unblinded(reviewer: file.reviewer, preferences: preferences)
    }
}
