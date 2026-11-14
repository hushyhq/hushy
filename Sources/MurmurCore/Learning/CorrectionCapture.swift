import Foundation

/// Everything the learning gate needs to know about where a dictation went. Built by the app
/// from the focus target and settings; nothing here is persisted.
public struct LearningContext: Sendable, Equatable {
    /// "Learn from my edits" (Settings). Off → nothing is captured.
    public var isEnabled: Bool
    public var appBundleID: String?
    /// Apps the user excluded from learning ("Don't learn in this app").
    public var excludedBundleIDs: Set<String>
    /// The field is a secure/password field (AX role or subrole says so).
    public var isSecureField: Bool
    /// Password managers and credential surfaces (`ContextReader`'s denylist).
    public var isDenylistedApp: Bool
    /// Code editors and terminals: edits there are code, not corrections of speech.
    public var isCodeContext: Bool
    /// Detected language of the dictation (nil = English). The classifier is English-only.
    public var detectedLanguage: String?
    /// Seconds between the paste and the moment the field was read.
    public var elapsed: TimeInterval

    public init(
        isEnabled: Bool = true, appBundleID: String? = nil, excludedBundleIDs: Set<String> = [],
        isSecureField: Bool = false, isDenylistedApp: Bool = false, isCodeContext: Bool = false,
        detectedLanguage: String? = nil, elapsed: TimeInterval = 8
    ) {
        self.isEnabled = isEnabled
        self.appBundleID = appBundleID
        self.excludedBundleIDs = excludedBundleIDs
        self.isSecureField = isSecureField
        self.isDenylistedApp = isDenylistedApp
        self.isCodeContext = isCodeContext
        self.detectedLanguage = detectedLanguage
        self.elapsed = elapsed
    }
}

/// Why a field read was not used for learning. Checked before the field text is even looked at.
public enum LearningRefusal: String, Sendable, Equatable {
    case disabled, excludedApp, secureField, denylistedApp, codeContext, nonEnglish, tooLate
}

public enum LearningGate {
    /// Edits read later than this after the paste are not treated as corrections of the
    /// dictation (the user has moved on and is writing, not fixing).
    public static let maxEditAge: TimeInterval = 60

    public static func refusal(_ context: LearningContext) -> LearningRefusal? {
        if !context.isEnabled { return .disabled }
        if context.isSecureField { return .secureField }
        if context.isDenylistedApp { return .denylistedApp }
        if let bundleID = context.appBundleID, context.excludedBundleIDs.contains(bundleID) { return .excludedApp }
        if context.isCodeContext { return .codeContext }
        if let language = context.detectedLanguage, language != "en", !language.hasPrefix("en-") { return .nonEnglish }
        if context.elapsed > maxEditAge || context.elapsed < 0 { return .tooLate }
        return nil
    }
}

/// One in-memory read of the target field, `elapsed` seconds after the paste. `value` is nil
/// when the field could not be read (gone, or no text value).
public struct FieldSnapshot: Sendable, Equatable {
    public let value: String?
    public let elapsed: TimeInterval
    /// The look taken as Return went down (`FieldRead.onReturn`).
    public let onReturn: Bool
    /// The text the field held right before it emptied, seen on a change read (`LearningReads.resolve`): the person
    /// had stopped typing and sent it, so it is never a word caught half typed.
    public let lastBeforeClear: Bool

    public init(value: String?, elapsed: TimeInterval, onReturn: Bool = false, lastBeforeClear: Bool = false) {
        self.value = value
        self.elapsed = elapsed
        self.onReturn = onReturn
        self.lastBeforeClear = lastBeforeClear
    }
}

/// The corrections derived from one dictation's field read: short strings only, never the
/// field's contents.
public struct CorrectionCapture: Sendable, Equatable {
    public let dictationID: Int64
    public let appBundleID: String?
    public let capturedAt: Date
    public let events: [CorrectionEvent]
    /// Term keys whose single edit was verified against the pasted span and surrounding field.
    public let oneEditSpellingKeys: Set<String>
    public let supportedKeys: Set<String>
    public let reverts: [Revert]

    public init(dictationID: Int64, appBundleID: String?, capturedAt: Date, events: [CorrectionEvent], oneEditSpellingKeys: Set<String> = [], supportedKeys: Set<String> = [], reverts: [Revert] = []) {
        self.dictationID = dictationID
        self.appBundleID = appBundleID
        self.capturedAt = capturedAt
        self.events = events
        self.oneEditSpellingKeys = oneEditSpellingKeys
        self.supportedKeys = supportedKeys
        self.reverts = reverts
    }

    /// Dictations shorter than this can't be located in a field by matching alone; `deriveLatest`
    /// sends one- and two-word dictations to `ShortDictationCapture`, which anchors on an earlier read.
    public static let minInsertedWords = 3
    /// More than this share of the dictation changed → a rewrite, not a correction.
    public static let maxChangedShare = 0.4
    /// More separate changed runs than this → the user was editing, not fixing.
    public static let maxEditRuns = 4

    /// Derives correction events from the text we inserted, the raw ASR transcript and the
    /// field's value a few seconds later. Returns nil when the gate refuses, the dictation
    /// can't be located, nothing changed, or the change is too large to be a correction.
    /// The field value is only read inside this call and never stored.
    public static func derive(
        inserted: String, raw: String, fieldValue: String?, context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionCapture? {
        explain(inserted: inserted, raw: raw, fieldValue: fieldValue, context: context, dictationID: dictationID,
                now: now, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord).capture
    }

    /// `derive`, with the reason when there is nothing to learn (for the `learning` log line).
    public static func explain(
        inserted: String, raw: String, fieldValue: String?, context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionDerivation {
        if let refusal = LearningGate.refusal(context) { return .dropped(.refused(refusal)) }
        guard let fieldValue else { return .dropped(.unreadable) }
        guard !fieldValue.contains(inserted) else { return .dropped(.unchanged) }
        guard !fieldValue.allSatisfy(\.isWhitespace) else { return .dropped(.cleared) }
        let words = CorrectionAlignment.tokens(inserted).count
        guard words >= minInsertedWords else { return .dropped(.tooFewWords(words)) }
        guard let alignment = CorrectionAlignment.locate(inserted: inserted, in: fieldValue) else { return .dropped(.notLocated) }
        guard !alignment.edits.isEmpty || !alignment.surfaceChanges.isEmpty else { return .dropped(.unchanged) }
        let changedShare = Double(max(alignment.changedInsertedWords, alignment.addedWords)) / Double(alignment.inserted.count)
        guard changedShare <= maxChangedShare else { return .dropped(.shareChanged(percent: Int((changedShare * 100).rounded()))) }
        guard alignment.edits.count <= maxEditRuns else { return .dropped(.editRuns(alignment.edits.count)) }
        let split = RevertDetector.split(alignment, swaps: swaps)
        let styled = StyleEditSignals.split(split.rest)
        let classified = CorrectionClassifier.classify(styled.rest, raw: raw, evidence: evidence, isCommonWord: isCommonWord) + styled.events
        let events = classified.filter { $0.kind != .rewrite }
        guard !events.isEmpty || !split.reverts.isEmpty else { return .dropped(.rewrite(changes: classified.count)) }
        let fieldKeys = CorrectionAlignment.tokens(fieldValue).map(CorrectionAlignment.key)
        let spanKeys = alignment.edited.map(CorrectionAlignment.key)
        let pastedKeys = alignment.inserted.map(CorrectionAlignment.key)
        let eligible = Set(events.compactMap { event -> String? in
            guard event.kind == .asrTerm else { return nil }
            let key = CorrectionAlignment.key(event.after)
            // A spelling already present elsewhere in the user's field is not new evidence.
            guard !pastedKeys.contains(key),
                  fieldKeys.filter({ $0 == key }).count == spanKeys.filter({ $0 == key }).count
            else { return nil }
            return key
        })
        return .capture(CorrectionCapture(dictationID: dictationID, appBundleID: context.appBundleID, capturedAt: now,
                                          events: events, oneEditSpellingKeys: eligible,
                                          supportedKeys: Set(events.filter { $0.kind == .asrTerm && $0.before.lowercased() != $0.after.lowercased() && evidence.supports($0.after) && eligible.contains(CorrectionAlignment.key($0.after)) }.map { $0.after.lowercased() }), reverts: split.reverts))
    }

    /// Derives from several reads of the same field and keeps the newest one that shows a
    /// correction. A fix that was typed and sent (the field then empties) between two looks is
    /// still learned from the look that saw it; a later look that sees nothing cannot erase it.
    /// Each read is gated on its own age. Identical neighbouring reads are derived once.
    ///
    /// A read can land half-way through typing a word. The one-letter spelling shortcut
    /// (`oneEditSpellingKeys`) is therefore granted per spelling: a key keeps it only when it is
    /// eligible in what at least `minStableReads` reads derived (identical reads count once
    /// each). The corrected word can stay the same while the person keeps typing after it, so
    /// the rest of the field is allowed to change. A spelling seen on a single read still
    /// teaches the ordinary way (a candidate that needs repeats).
    ///
    /// What this drops (the changed passage itself, and every rewrite) memory keeps as
    /// before-and-after pairs from the same reads: `EditPair.derive`.
    public static func deriveLatest(
        inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionCapture? {
        explainLatest(inserted: inserted, raw: raw, snapshots: snapshots, context: context, dictationID: dictationID,
                      now: now, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord).capture
    }

    /// `deriveLatest`, with the reason when no look taught anything (`rank` picks the look that says
    /// why); with no readable look the answer is `unreadable`.
    public static func explainLatest(
        inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext,
        dictationID: Int64, now: Date = Date(), evidence: TermEvidence = .none, swaps: [VocabularySwap] = [],
        isCommonWord: (String) -> Bool = LearningLexicon.isCommonWord
    ) -> CorrectionDerivation {
        if ShortDictationCapture.qualifies(inserted) {
            return ShortDictationCapture.explain(
                inserted: inserted, raw: raw, snapshots: snapshots, context: context,
                dictationID: dictationID, now: now, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord)
        }
        var derived: [String: CorrectionDerivation] = [:]
        func derivation(at snapshot: FieldSnapshot, value: String) -> CorrectionDerivation {
            if let known = derived[value] { return known }
            var atRead = context
            atRead.elapsed = snapshot.elapsed
            let result = explain(inserted: inserted, raw: raw, fieldValue: value, context: atRead,
                                 dictationID: dictationID, now: now, evidence: evidence, swaps: swaps, isCommonWord: isCommonWord)
            derived[value] = result
            return result
        }
        func capture(at snapshot: FieldSnapshot, value: String) -> CorrectionCapture? {
            derivation(at: snapshot, value: value).capture
        }
        var seen: Set<String> = []
        var drop: CorrectionDrop?
        for index in snapshots.indices.reversed() {
            let snapshot = snapshots[index]
            guard let value = snapshot.value, seen.insert(value).inserted else { continue }
            guard let found = capture(at: snapshot, value: value) else {
                if case .dropped(let reason) = derivation(at: snapshot, value: value), drop.map({ rank(reason) > rank($0) }) ?? true {
                    drop = reason
                }
                continue
            }
            guard let latest = settled(found, at: index, in: snapshots, inserted: inserted) else {
                if drop.map({ rank(.notSettled) > rank($0) }) ?? true { drop = .notSettled }
                continue
            }
            // A spelling keeps the one-letter shortcut only if it shows up in what at least
            // `minStableReads` reads derived. The rest of the field may still be changing.
            var reads: [String: Int] = [:]
            for other in snapshots.reversed() {
                guard let otherValue = other.value, let seenAt = capture(at: other, value: otherValue) else { continue }
                for key in seenAt.oneEditSpellingKeys { reads[key, default: 0] += 1 }
            }
            let stable = latest.oneEditSpellingKeys.filter { reads[$0, default: 0] >= minStableReads }
            return .capture(CorrectionCapture(dictationID: latest.dictationID, appBundleID: latest.appBundleID,
                                              capturedAt: latest.capturedAt, events: latest.events,
                                              oneEditSpellingKeys: stable, supportedKeys: latest.supportedKeys.filter { stable.contains(CorrectionAlignment.key($0)) }, reverts: latest.reverts))
        }
        return .dropped(drop ?? .unreadable)
    }

    /// Which look names the reason nothing was learned: the newest look that saw the dictation changed, else one that
    /// saw it unchanged, and only when no look saw it at all one that found the field empty or holding other text. A
    /// chat message sent as it was, or rewritten and then sent, is not reported as a cleared field.
    private static func rank(_ drop: CorrectionDrop) -> Int {
        switch drop {
        case .cleared, .notLocated: 0
        case .unchanged: 1
        default: 2
        }
    }

    /// Reads that must show the same field value before the one-letter shortcut is trusted.
    public static let minStableReads = 2

    /// Two looks this close together that spell the same heard word two ways caught the person typing it.
    static let stillTypingWindow: TimeInterval = 2

    /// `capture` without the terms the person was still typing when its look was taken. A term counts as half-typed
    /// when its look is the only one that held that field text, was not taken on Return or seen last before the field
    /// emptied (`FieldSnapshot.lastBeforeClear`), and the nearest earlier look
    /// with other text, taken within `stillTypingWindow`, held the same heard word spelled another way ("Kar" before
    /// "Karthi"). Nil when only such terms were found.
    static func settled(_ capture: CorrectionCapture, at index: Int, in snapshots: [FieldSnapshot], inserted: String) -> CorrectionCapture? {
        let snapshot = snapshots[index]
        guard let value = snapshot.value, !snapshot.onReturn, !snapshot.lastBeforeClear,
              snapshots.filter({ $0.value == value }).count < minStableReads,
              let look = snapshots[..<index].last(where: { $0.value.map { $0 != value && !$0.allSatisfy(\.isWhitespace) } ?? false }),
              snapshot.elapsed - look.elapsed <= stillTypingWindow, let earlier = look.value,
              let alignment = CorrectionAlignment.locate(inserted: inserted, in: earlier)
        else { return capture }
        func keys(_ text: String) -> [String] { CorrectionAlignment.tokens(text).map(CorrectionAlignment.key) }
        let typing = capture.events.filter { event in
            event.kind == .asrTerm && alignment.edits.contains { edit in
                edit.before.map(CorrectionAlignment.key) == keys(event.before) && edit.after.map(CorrectionAlignment.key) != keys(event.after)
            }
        }
        guard !typing.isEmpty else { return capture }
        let events = capture.events.filter { !typing.contains($0) }
        guard !events.isEmpty || !capture.reverts.isEmpty else { return nil }
        let unsettled = Set(typing.map { CorrectionAlignment.key($0.after) })
        return CorrectionCapture(dictationID: capture.dictationID, appBundleID: capture.appBundleID, capturedAt: capture.capturedAt,
                                 events: events, oneEditSpellingKeys: capture.oneEditSpellingKeys.subtracting(unsettled),
                                 supportedKeys: capture.supportedKeys.filter { !unsettled.contains(CorrectionAlignment.key($0)) },
                                 reverts: capture.reverts)
    }
}
