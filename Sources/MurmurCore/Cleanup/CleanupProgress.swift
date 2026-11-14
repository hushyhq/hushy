import Foundation

/// How far the cleanup of one long dictation has got: sentence groups finished out of the groups
/// there are, and the words in them. The optional latest group text is in memory for the pill;
/// diagnostics and usage reports read only the counts.
///
/// Sent only for a dictation cleaned group by group (`SmartCleaner.cleanSegmented`): once before
/// the first group, with nothing done, then once as each group's text is settled, in order. A
/// dictation cleaned in one call sends nothing, because there is no honest fraction to give for it.
/// Groups cleaned while the person was still speaking count as done the moment they are reached.
public struct CleanupProgress: Sendable, Equatable {
    public let groupsDone: Int
    public let groupCount: Int
    public let wordsDone: Int
    public let wordCount: Int
    /// Settled text from the latest completed group, held only by the pill observer.
    public let latestText: String?

    public init(groupsDone: Int, groupCount: Int, wordsDone: Int, wordCount: Int, latestText: String? = nil) {
        self.groupsDone = groupsDone
        self.groupCount = groupCount
        self.wordsDone = wordsDone
        self.wordCount = wordCount
        self.latestText = latestText
    }

    /// The share of the dictation's words whose cleanup is settled, 0 to 1.
    public var fraction: Double {
        guard wordCount > 0 else { return 0 }
        return min(1, max(0, Double(wordsDone) / Double(wordCount)))
    }
}

/// Told about cleanup progress. Called from the cleaner's own executor and never awaited: it must
/// return at once (hop to wherever the work is shown) and can never change what cleanup produces.
public typealias CleanupProgressObserver = @Sendable (CleanupProgress) -> Void
