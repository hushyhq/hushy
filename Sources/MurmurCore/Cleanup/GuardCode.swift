import Foundation

/// Which check threw a model answer away, as a closed set of names that carry no text.
///
/// The guards build their reasons for people reading a failing eval ("kept retracted item: off the dry
/// cleaning"), and a reason can quote the speaker's words. A reason string must therefore never reach a
/// log line, a saved row or a metric. This type is the only form that may: it is made from the fixed
/// phrase in front of the colon, matched against a closed table, and anything that is not in the table
/// is `.other`, so a new guard can add free text to its reason without it leaking.
public enum GuardCode: String, CaseIterable, Sendable, Codable {
    case addedWords = "added-words"
    case addedContentWords = "added-content-words"
    case addedNegation = "added-negation"
    case addedOrReorderedContent = "added-or-reordered-content"
    case changedAddress = "changed-address"
    case changedConnective = "changed-connective"
    case changedDigits = "changed-digits"
    case changedLocalGrammarWord = "changed-local-grammar-word"
    case changedName = "changed-name"
    case changedProtectedTerm = "changed-protected-term"
    case changedUnmarkedWord = "changed-unmarked-word"
    case changedLiteral = "changed-literal"
    case changedCodeText = "changed-code-text"
    case changedModalOrQuantifier = "changed-modal-or-quantifier"
    case changedQuestionOrEmphasis = "changed-question-or-emphasis"
    case collapsedDoubledWord = "collapsed-a-legitimate-doubled-word"
    case droppedAdmission = "dropped-admission"
    case droppedClarificationLeadIn = "dropped-clarification-lead-in"
    case droppedContrastiveActually = "dropped-contrastive-actually"
    case droppedHedge = "dropped-hedge"
    case droppedIdentifier = "dropped-identifier"
    case droppedPurposePhrase = "dropped-purpose-phrase"
    case droppedMarkedWord = "dropped-marked-word"
    case droppedNegation = "dropped-negation"
    case droppedNumber = "dropped-number"
    case droppedStanceWord = "dropped-stance-word"
    case droppedTrailingClause = "dropped-trailing-clause"
    case droppedTrailOff = "dropped-trail-off"
    case droppedContentWords = "dropped-content-words"
    case droppedTooMuch = "dropped-too-much"
    case droppedLeadingRequest = "dropped-leading-request"
    case droppedClauseBeforeHedge = "dropped-clause-before-hedge"
    case keptRetractedClause = "kept-retracted-clause"
    case keptRetractedItem = "kept-retracted-item"
    case reasonDetachedFromRetracted = "reason-detached-from-retracted-item"
    case languageMismatch = "language-mismatch"
    case listWithoutSignal = "list-without-signal"
    case spokenLayoutChanged = "spoken-layout-changed"
    case longerThanDraft = "longer-than-draft"
    case reorderedOrDroppedContent = "reordered-or-dropped-content"
    case reorderedWords = "reordered-words"
    case replacedContentWords = "replaced-content-words"
    case grammarNotVerified = "grammar-not-verified"
    case notARewrite = "not-a-rewrite"
    case rankedBelowRules = "ranked-below-rules"
    case emptyAnswer = "empty"
    case other

    /// The code for a guard's reason. Only the fixed phrase in front of the first colon is read.
    public init(reason: String) {
        let head = reason.split(separator: ":", maxSplits: 1).first.map(String.init) ?? reason
        let key = head.lowercased().trimmingCharacters(in: .whitespaces)
        self = Self.table[key] ?? .other
    }

    private static let table: [String: GuardCode] = [
        "added words": .addedWords, "added content words": .addedContentWords,
        "added negation": .addedNegation, "added or reordered content": .addedOrReorderedContent,
        "changed address": .changedAddress, "changed connective": .changedConnective,
        "changed digits": .changedDigits, "changed local grammar word": .changedLocalGrammarWord,
        "changed name": .changedName, "changed protected term": .changedProtectedTerm,
        "changed unmarked word": .changedUnmarkedWord, "changed backtick literal": .changedLiteral,
        "changed code-context text": .changedCodeText, "code context must remain byte-identical": .changedCodeText,
        "changed modal or quantifier": .changedModalOrQuantifier,
        "changed question or emphasis punctuation": .changedQuestionOrEmphasis,
        "collapsed a legitimate doubled word": .collapsedDoubledWord,
        "dropped admission": .droppedAdmission, "dropped clarification lead-in": .droppedClarificationLeadIn,
        "dropped contrastive actually": .droppedContrastiveActually, "dropped hedge": .droppedHedge, "dropped identifier": .droppedIdentifier, "dropped purpose phrase": .droppedPurposePhrase,
        "dropped marked word": .droppedMarkedWord, "dropped negation": .droppedNegation,
        "dropped number": .droppedNumber, "dropped stance word": .droppedStanceWord,
        "dropped trailing clause": .droppedTrailingClause, "dropped trail-off": .droppedTrailOff, "dropped content words": .droppedContentWords,
        "dropped too much": .droppedTooMuch, "dropped-leading-request": .droppedLeadingRequest,
        "dropped-clause-before-hedge": .droppedClauseBeforeHedge,
        "kept retracted clause": .keptRetractedClause, "kept retracted item": .keptRetractedItem,
        "reason detached from retracted item": .reasonDetachedFromRetracted,
        "language mismatch": .languageMismatch, "list-without-signal": .listWithoutSignal,
        "spoken-layout-changed": .spokenLayoutChanged, "longer than draft": .longerThanDraft,
        "reordered or dropped content": .reorderedOrDroppedContent, "reordered words": .reorderedWords,
        "replaced content words": .replacedContentWords,
        "grammar verification rejected, uncertain, or unavailable": .grammarNotVerified,
        "not a rewrite": .notARewrite, "ranked below rules": .rankedBelowRules, "empty": .emptyAnswer,
    ]

    /// What the check protects, in words a person can read in History.
    public var plainName: String {
        switch self {
        case .changedName, .changedProtectedTerm: "a name or term you keep"
        case .changedDigits, .droppedNumber: "a number"
        case .addedNegation, .droppedNegation: "a \"not\""
        case .keptRetractedItem, .keptRetractedClause, .reasonDetachedFromRetracted, .droppedTrailingClause:
            "something you took back"
        case .spokenLayoutChanged, .listWithoutSignal: "line breaks or list layout"
        case .languageMismatch: "the language you spoke"
        case .changedCodeText, .changedLiteral, .changedAddress: "literal text such as code or an address"
        case .rankedBelowRules: "the model's version was no better than the plain one"
        case .grammarNotVerified: "a grammar fix that could not be confirmed"
        default: "the meaning of what you said"
        }
    }
}
