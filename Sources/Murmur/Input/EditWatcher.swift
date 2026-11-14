import AppKit
import ApplicationServices
import MurmurCore
import os

/// Observes only the exact text field captured when dictation began. It stores a typed verdict
/// and coverage reason; field contents are read in memory and discarded.
@MainActor
enum EditWatcher {
    /// When the field is read, and which read is the edit verdict: `LearningReadSchedule`. Reads
    /// every half second to 6 s catch a fix sent from a chat box before the
    /// verdict read; reads every 4 s after it (to 30 s) catch slower fixes. Only the 8 s read decides the verdict.

    /// What the learning loop needs besides the field. `nil` means don't learn from this
    /// dictation; edit observation remains independent of learning settings.
    struct LearningInput {
        let raw: String
        let context: LearningContext
        var swaps: [VocabularySwap] = []
        var evidence: TermEvidence = .none
        var isStillAllowed: @MainActor () -> Bool = { true }
        var policy: LearningPolicy? = nil
    }

    /// Told, once, what the verdict read decided (usage numbers hold a dictation until then): the verdict, why it
    /// could or could not be reached, and, for an edited dictation, how many words changed (`none` otherwise).
    typealias VerdictHandler = @MainActor (DictationEditObservation.Verdict, DictationEditObservation.Coverage, MetricsEditSize) -> Void

    struct ReadResult {
        let fieldValue: String?
        let coverage: DictationEditObservation.Coverage
    }

    private static let log = Logger(subsystem: "app.hushy", category: "learning")

    /// What one dictation's watch came to, heard once when it ends.
    typealias Reporter = @MainActor (LearningDiagnosis) -> Void

    /// Starts listening for the watched field's own "value changed" reports, calling the handler on the main actor for
    /// each; returns what stops listening. The default listens to nothing.
    typealias ChangeSubscriber = @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    /// The one `learning` line a dictation gets: fixed words, numbers and the app's bundle id.
    static func report(_ diagnosis: LearningDiagnosis) {
        log.notice("\(diagnosis.line, privacy: .public)")
    }

    /// Why a finished dictation is not watched at all, or nil when it is.
    nonisolated static func notWatched(isSaved: Bool, status: Dictation.Status, pressesReturn: Bool) -> LearningDiagnosis.NotWatched? {
        if !isSaved { return .notSaved }
        if status != .inserted { return .notInserted }
        return pressesReturn ? .spokenReturn : nil
    }

    /// Whether a pasted dictation may be learned from: the input when it may, the gate's reason
    /// when it may not. Observation runs either way.
    enum Learning {
        case allowed(LearningInput)
        case refused(LearningRefusal)

        var input: LearningInput? {
            if case .allowed(let input) = self { return input }
            return nil
        }

        var refusal: LearningRefusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }
    }

    static func learning(
        raw: String, target: FocusTarget, settings: AppSettings, detectedLanguage: String?,
        swaps: [VocabularySwap] = [], evidence: TermEvidence = .none
    ) -> Learning {
        let context = LearningContext(
            isEnabled: settings.learnFromEdits, appBundleID: target.bundleID,
            excludedBundleIDs: settings.learningExcludedApps,
            isDenylistedApp: ContextReader.isDenylisted(bundleID: target.bundleID),
            isCodeContext: target.category == .code, detectedLanguage: detectedLanguage, elapsed: 0)
        if let refusal = LearningGate.refusal(context) { return .refused(refusal) }
        return .allowed(LearningInput(raw: raw, context: context, swaps: swaps, evidence: evidence, isStillAllowed: {
            settings.learnFromEdits && !settings.learningExcludedApps.contains(target.bundleID ?? "")
        }))
    }


    /// Called only for a successful nonempty paste (never for clipboard delivery, Return actions,
    /// cancellation, or failure). A missing AX field is immediately recorded as unreadable.
    /// `refusal` is why `learning` is nil, and `app` the app pasted into: both only for the
    /// `learning` log line.
    static func watch(
        element: AXUIElement?, inserted: String, dictationID: Int64, store: Store, learning: LearningInput? = nil,
        refusal: LearningRefusal? = nil, app: String? = nil, memory: MemoryStore? = nil, onVerdict: VerdictHandler? = nil,
        report: @escaping Reporter = EditWatcher.report
    ) {
        guard !inserted.isEmpty else { return }
        guard let element else {
            record(.unknown, coverage: .fieldUnreadable, dictationID: dictationID, store: store, expectedInsertedText: inserted)
            onVerdict?(.unknown, .fieldUnreadable, MetricsEditSize.none)
            var diagnosis = LearningDiagnosis(bundleID: app ?? learning?.context.appBundleID, outcome: .unreadable(atLook: nil))
            diagnosis.verdict = DictationEditObservation.Verdict.unknown.rawValue
            diagnosis.coverage = DictationEditObservation.Coverage.fieldUnreadable.rawValue
            report(diagnosis)
            return
        }
        _ = observe(inserted: inserted, dictationID: dictationID, store: store, learning: learning, refusal: refusal,
                    app: app, memory: memory, onVerdict: onVerdict, report: report,
                    readField: { read(element) },
                    boundReads: { bounded in AXUIElementSetMessagingTimeout(element, bounded ? learningReadTimeout : 0) },
                    subscribeChanges: { FieldChangeObserver.subscribe(element, onChange: $0) })
    }

    /// Injectable field reader and clock for deterministic observation/lifecycle tests.
    /// `boundReads(true)` asks the reader to give up quickly (learning-only looks);
    /// `boundReads(false)` restores the system default (the verdict look, and the end).
    /// `memory` is where the person's changes are kept as before-and-after pairs; nil keeps none.
    /// `report` hears, once, what the watch came to. `subscribeChanges` listens to the field's own change reports
    /// while the watch learns (`LiveEditWatch.readOnChange`).
    @discardableResult
    static func observe(
        inserted: String, dictationID: Int64, store: Store, learning: LearningInput? = nil, refusal: LearningRefusal? = nil,
        app: String? = nil, memory: MemoryStore? = nil, onVerdict: VerdictHandler? = nil,
        report: @escaping Reporter = EditWatcher.report,
        readField: @escaping @MainActor () -> ReadResult,
        boundReads: @escaping @MainActor (Bool) -> Void = { _ in },
        subscribeChanges: @escaping ChangeSubscriber = { _ in {} },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Task<Void, Never> {
        let generation = try? store.editObservationGeneration(forDictation: dictationID)
        let watch = Watch(inserted: inserted, dictationID: dictationID, store: store, learning: learning, refusal: refusal,
                          app: app ?? learning?.context.appBundleID, memory: memory, onVerdict: onVerdict)
        return Task { @MainActor in
            report(await looks(watch, generation: generation, readField: readField, boundReads: boundReads,
                               subscribeChanges: subscribeChanges, sleep: sleep))
        }
    }

    /// One pasted dictation being watched.
    private struct Watch {
        let inserted: String
        let dictationID: Int64
        let store: Store
        let learning: LearningInput?
        let refusal: LearningRefusal?
        let app: String?
        let memory: MemoryStore?
        let onVerdict: VerdictHandler?
    }

    /// Takes the scheduled looks, records the verdict, learns, and says what it all came to.
    private static func looks(
        _ watch: Watch, generation: String?, readField: @escaping @MainActor () -> ReadResult,
        boundReads: @escaping @MainActor (Bool) -> Void, subscribeChanges: ChangeSubscriber,
        sleep: @MainActor (Duration) async throws -> Void
    ) async -> LearningDiagnosis {
        var diagnosis = LearningDiagnosis(bundleID: watch.app, outcome: .stopped(.noRecord))
        guard let generation else { return diagnosis }
        let inserted = watch.inserted, dictationID = watch.dictationID, store = watch.store
        let pastedAt = Date()
        var active = watch.learning
        var wasSwitchedOff = false
        var verdictRead = false
        // A Return press in the watched app takes one extra look through this (`returnPressed`).
        let live = LiveEditWatch(app: watch.app, pastedAt: pastedAt, learning: active, readField: readField, boundReads: boundReads,
                                 isCurrent: { (try? store.isCurrentEditObservation(dictationID: dictationID, expectedInsertedText: inserted, expectedGeneration: generation)) == true })
        register(live)
        // Only a watch that learns listens for the field's changes; the verdict alone never needs them.
        var stopListening: @MainActor () -> Void = {}
        if active != nil { stopListening = subscribeChanges { [weak live] in live?.readOnChange() } }
        // Leave the element as the app expects it: no lingering short timeout.
        defer {
            stopListening()
            unregister(live)
            boundReads(false)
        }
        for offset in LearningReadSchedule.offsets {
            let isVerdict = offset == LearningReadSchedule.verdictOffset
            // Reads before the verdict only feed learning: skip them when nothing can learn.
            if offset < LearningReadSchedule.verdictOffset, active == nil { continue }
            // Sleep to the scheduled moment, not by the gap, so read time never pushes the verdict read later.
            do { try await sleep(.seconds(max(0, offset - Date().timeIntervalSince(pastedAt)))) } catch {
                diagnosis.outcome = .stopped(.cancelled)
                return diagnosis
            }
            guard !Task.isCancelled else {
                diagnosis.outcome = .stopped(.cancelled)
                return diagnosis
            }
            guard (try? store.isCurrentEditObservation(dictationID: dictationID, expectedInsertedText: inserted, expectedGeneration: generation)) == true
            else {
                diagnosis.outcome = .stopped(.superseded)
                return diagnosis
            }
            // Learning switched off (or the app excluded) while waiting: keep the verdict, stop learning.
            if let current = active, !current.isStillAllowed() {
                active = nil
                live.learning = nil
                wasSwitchedOff = true
            }
            if !isVerdict, active == nil { if verdictRead { break } else { continue } }
            // Non-verdict looks give up quickly on a hung app; the verdict look keeps the system default.
            boundReads(!isVerdict)
            let look = readField()
            if isVerdict {
                verdictRead = true
                let outcome = await observation(inserted: inserted, read: look)
                record(outcome.verdict, coverage: outcome.coverage, dictationID: dictationID, store: store,
                       expectedInsertedText: inserted, expectedGeneration: generation)
                watch.onVerdict?(outcome.verdict, outcome.coverage, outcome.size)
                diagnosis.verdict = outcome.verdict.rawValue
                diagnosis.coverage = outcome.coverage.rawValue
            }
            live.record(look)
            diagnosis.looks = live.reads.count
            diagnosis.readable = live.reads.filter { $0.value != nil }.count
            if isVerdict, active == nil { break }
        }
        live.close()
        let reads = live.reads
        diagnosis.looks = reads.count
        diagnosis.readable = reads.filter { $0.value != nil }.count
        diagnosis.changeLooks = live.changeReads
        guard verdictRead else {
            diagnosis.outcome = .stopped(.noVerdict)
            return diagnosis
        }
        guard let active else {
            diagnosis.outcome = wasSwitchedOff ? .notLearning(.switchedOff)
                : watch.refusal.map { .refused($0) } ?? .notLearning(.notAsked)
            return diagnosis
        }
        let resolved = LearningReads.resolve(reads)
        diagnosis.beforeClear = resolved.snapshots.filter(\.lastBeforeClear).count
        var context = active.context
        context.isSecureField = resolved.isSecureField
        let firstUnreadable = (reads.firstIndex { $0.value == nil } ?? 0) + 1
        let learned = await learn(inserted: inserted, raw: active.raw, snapshots: resolved.snapshots, context: context,
                                  dictationID: dictationID, store: store, expectedInsertedText: inserted, expectedGeneration: generation,
                                  memory: watch.memory, pastedAt: pastedAt, swaps: active.swaps, evidence: active.evidence, policy: active.policy ?? .current)
        diagnosis.outcome = learned.outcome == .unreadable(atLook: nil) ? .unreadable(atLook: firstUnreadable) : learned.outcome
        diagnosis.pairs = learned.pairs
        return diagnosis
    }

    /// What the verdict read decided. `size` is how many words changed, for an edited dictation only; it is
    /// measured off the main actor, because it aligns the dictation with the field's text.
    private static func observation(
        inserted: String, read: ReadResult
    ) async -> (verdict: DictationEditObservation.Verdict, coverage: DictationEditObservation.Coverage, size: MetricsEditSize) {
        let none = MetricsEditSize.none
        guard read.coverage == .observed else {
            return (.unknown, read.coverage, none)
        }
        guard let fieldValue = read.fieldValue else { return (.unknown, .fieldUnreadable, none) }
        if fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.unknown, .fieldCleared, none)
        }
        guard let verdict = EditVerdict.judge(inserted: inserted, fieldValue: fieldValue) else {
            return (.unknown, .insufficientSignal, none)
        }
        guard verdict == .edited else { return (.kept, .observed, none) }
        let size = await Task.detached(priority: .utility) {
            EditSizeMeasure.size(inserted: inserted, fieldValue: fieldValue)
        }.value
        return (.edited, .observed, size)
    }

    private static func record(
        _ verdict: DictationEditObservation.Verdict, coverage: DictationEditObservation.Coverage,
        dictationID: Int64, store: Store, expectedInsertedText: String, expectedGeneration: String? = nil
    ) {
        do {
            let observation = try DictationEditObservation(dictationID: dictationID, verdict: verdict, coverage: coverage)
            _ = try store.recordEditObservation(observation, expectedInsertedText: expectedInsertedText, expectedGeneration: expectedGeneration)
        } catch {
            log.error("could not record edit coverage: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A hung target app must not freeze the main actor for the system default (about six
    /// seconds) on every learning look.
    private static let learningReadTimeout: Float = 0.25

    /// Checks security before requesting AXValue and rechecks immediately afterward. No AXValue
    /// call is made for a secure or unknown-security field. The caller sets the per-call timeout.
    private static func read(_ element: AXUIElement) -> ReadResult {
        switch ContextReader.security(of: element) {
        case .secure: return ReadResult(fieldValue: nil, coverage: .secure)
        case .unknown: return ReadResult(fieldValue: nil, coverage: .unknownSecurity)
        case .notSecure: break
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        switch ContextReader.security(of: element) {
        case .secure: return ReadResult(fieldValue: nil, coverage: .secure)
        case .unknown: return ReadResult(fieldValue: nil, coverage: .unknownSecurity)
        case .notSecure: break
        }
        guard result == .success, let fieldValue = value as? String else {
            return ReadResult(fieldValue: nil, coverage: .fieldUnreadable)
        }
        return ReadResult(fieldValue: fieldValue, coverage: .observed)
    }

    /// Derives and persists off the main actor (alignment and the word list are not free); only
    /// the derived short strings reach the database, the snapshots go out of scope here. Says
    /// what it came to, and how many pairs memory kept (nil when memory is not in this build).
    private static func learn(
        inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext, dictationID: Int64,
        store: Store, expectedInsertedText: String, expectedGeneration: String? = nil,
        memory: MemoryStore? = nil, pastedAt: Date = Date(), swaps: [VocabularySwap] = [], evidence: TermEvidence = .none, policy: LearningPolicy
    ) async -> (outcome: LearningDiagnosis.Outcome, pairs: Int?) {
        if let refusal = LearningGate.refusal(context) { return (.refused(refusal), nil) }
        guard snapshots.contains(where: { $0.value != nil }) else { return (.unreadable(atLook: nil), nil) }
        let log = log
        return await Task.detached(priority: .utility) {
            // Once the person has dictated again the field may hold that dictation, which is Hushy's text and not
            // their change: only the looks from before it teach anything (terms, habits, left-alone counts, pairs).
            let next = (try? store.nextInsertedDictationDate(after: dictationID))?.timeIntervalSince(pastedAt)
            let snapshots = next.map { limit in snapshots.filter { $0.elapsed < limit } } ?? snapshots
            let derivation = CorrectionCapture.explainLatest(
                inserted: inserted, raw: raw, snapshots: snapshots, context: context, dictationID: dictationID, evidence: evidence, swaps: swaps)
            var outcome = LearningDiagnosis.Outcome.noChange
            switch derivation {
            case .dropped(.unchanged): break
            case .dropped(.unreadable): outcome = .unreadable(atLook: nil)
            case .dropped(.refused(let refusal)): outcome = .refused(refusal)
            case .dropped(let drop): outcome = .dropped(drop)
            case .capture(let capture):
                do {
                    let record = try store.reportCorrections(capture, policy: policy, expectedInsertedText: expectedInsertedText, expectedObservationGeneration: expectedGeneration)
                    outcome = Self.outcome(of: record)
                } catch {
                    log.error("could not record corrections: \(error.localizedDescription, privacy: .public)")
                    outcome = .failed
                }
            }
            Self.countLeftAlone(derivation, inserted: inserted, raw: raw, snapshots: snapshots, context: context, dictationID: dictationID,
                                store: store, expectedInsertedText: expectedInsertedText, expectedGeneration: expectedGeneration, policy: policy, log: log)
            guard let memory else { return (outcome, nil) }
            let pairs = EditPair.derive(inserted: inserted, snapshots: snapshots, context: context)
                .filter { CorrectionEditPairs.containsOnlyCorrections($0, raw: raw, evidence: evidence, swaps: swaps) }
            guard !pairs.isEmpty,
                  (try? store.isCurrentEditObservation(dictationID: dictationID, expectedInsertedText: expectedInsertedText, expectedGeneration: expectedGeneration)) == true
            else { return (outcome, 0) }
            return (outcome, await remember(pairs, context: context, memory: memory, log: log))
        }.value
    }

    /// Adds a "left alone" to each learned term that Hushy wrote as heard in this dictation and the person did not
    /// change (`ExposureDerivation`): the other half of the evidence that decides whether a swap is wanted. Counts
    /// only; the field's text is compared in memory and dropped. Runs under the same gate as learning itself.
    private nonisolated static func countLeftAlone(
        _ derivation: CorrectionDerivation, inserted: String, raw: String, snapshots: [FieldSnapshot], context: LearningContext,
        dictationID: Int64, store: Store, expectedInsertedText: String, expectedGeneration: String?, policy: LearningPolicy, log: Logger
    ) {
        guard policy.useEvidence, let watched = try? store.watchedTerms(app: context.appBundleID), !watched.isEmpty else { return }
        let editedKeys = Set((derivation.capture?.events ?? []).filter { $0.kind == .asrTerm }.map { $0.after.lowercased() })
        let values = snapshots.reversed().compactMap(\.value)
        guard let left = ExposureDerivation.leftAlone(inserted: inserted, raw: raw, fieldValues: values, watched: watched, editedKeys: editedKeys),
              !left.isEmpty else { return }
        do {
            try store.recordLeftAlone(left, app: context.appBundleID, dictationID: dictationID, policy: policy,
                                      expectedInsertedText: expectedInsertedText, expectedObservationGeneration: expectedGeneration)
        } catch {
            log.error("could not count a word left alone: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func outcome(of record: CorrectionRecord) -> LearningDiagnosis.Outcome {
        if record.keptHeard > 0 { return .kept(items: record.keptHeard, learned: record.activated.count, reactivated: record.reactivatedHeard) }
        if !record.activated.isEmpty { return .learned(items: record.activated.count) }
        if let progress = record.progress { return .candidate(items: record.written, seen: progress.seen, needed: progress.needed) }
        if record.written > 0 { return .alreadyLearned(items: record.written) }
        return .notRecorded(record.skip ?? .nothing)
    }

    /// The pairs go to `corrections.md` through the store's own gate (the same refusals, and
    /// Pause). Returns how many were kept, for the dictation's `learning` line.
    private nonisolated static func remember(_ pairs: [EditPair], context: LearningContext, memory: MemoryStore, log: Logger) async -> Int {
        var kept = 0
        do {
            for pair in pairs {
                let entry = MemoryEntry(kind: .correction, value: "", appBundleID: context.appBundleID,
                                        before: pair.before, after: pair.after)
                if case .kept = try await memory.learn(entry, context: context) { kept += 1 }
            }
        } catch {
            log.error("could not keep edit pairs: \(error.localizedDescription, privacy: .public)")
        }
        return kept
    }
}
