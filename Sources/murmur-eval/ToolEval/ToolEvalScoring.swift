import Foundation
import MurmurCore

/// What a backend answered for one case.
struct ToolEvalAnswer: Sendable {
    /// Empty = the backend left it as dictation (no reason given). One `no_action` call = an
    /// explicit no-action with a reason. Several calls = a multi-intent split.
    var calls: [ToolCall]
    /// Timeout, refusal, malformed output or unavailability. Scored like "no action" (the app
    /// falls back to plain dictation) and counted separately.
    var error: String?
    var latencyMs: Double
    /// When the tool name was known (streaming backends); nil when the seam can't observe it.
    var timeToToolNameMs: Double?
    /// Whether the model was asked at all (extractor mode; nil for backends that always ask).
    var modelCalled: Bool?
    /// Whether the app would have done this at once, with "Done · Undo", rather than show the
    /// confirm card (extractor mode, the default "Ask before doing" setting; nil when no action).
    var actsAtOnce: Bool?
}

/// One case, scored.
struct ToolEvalOutcome: Sendable {
    let item: ToolEvalCase
    let answer: ToolEvalAnswer
    /// Right tool (or `no_action` for negatives/refusals; an accepted split for multi-intent).
    let toolCorrect: Bool
    /// Right tool and every expected argument exact / tolerant (negatives: same as `toolCorrect`).
    let callExact: Bool
    let callTolerant: Bool
    /// A tool fired on a `no_action` case.
    let falseFire: Bool
    /// Refusal cases only: answered no-action (or an accepted split) / with an accepted reason.
    let refusalLenient: Bool?
    let refusalStrict: Bool?
    let slots: [String: (exact: Bool, tolerant: Bool)]
    let schemaValid: Bool

    /// The arguments that say where an item goes. Naming one the person did not say can stop the
    /// item being saved at all (a list that does not exist is refused, never swapped for the default).
    static let targetArguments = ["list", "calendar"]

    /// A command answered with the right tool whose expectation names no list or calendar.
    var expectsNoTarget: Bool {
        guard item.expect.decision == .call, toolCorrect, let predicted = answer.calls.first(where: { !$0.isNoAction }) else { return false }
        let expected = item.expect.acceptableCalls.filter { $0.tool == predicted.tool }
        return expected.allSatisfy { call in Self.targetArguments.allSatisfy { call.arguments[$0] == nil } }
    }

    /// …and the answer named one anyway.
    var namesUnaskedTarget: Bool {
        guard expectsNoTarget, let predicted = answer.calls.first(where: { !$0.isNoAction }) else { return false }
        return Self.targetArguments.contains { !(predicted.arguments[$0]?.isEmpty ?? true) }
    }

    var predictedLabel: String {
        if let error = answer.error { return "error: \(error)" }
        let real = answer.calls.filter { !$0.isNoAction }
        if real.isEmpty {
            return answer.calls.first?.noActionReason.map { "no_action(\($0.rawValue))" } ?? "no_action"
        }
        return real.map(ToolEvalScoring.describe).joined(separator: " + ")
    }
}

enum ToolEvalScoring {
    static func score(_ item: ToolEvalCase, _ answer: ToolEvalAnswer) -> ToolEvalOutcome {
        let real = answer.error == nil ? answer.calls.filter { !$0.isNoAction } : []
        let isNoAction = real.isEmpty
        let reason = answer.error == nil ? answer.calls.first?.noActionReason : nil
        let dates = dateContext(item)
        let schemaValid = answer.calls.allSatisfy { $0.validationIssues().isEmpty }

        switch item.expect.decision {
        case .call:
            guard real.count == 1, let predicted = real.first,
                  let comparison = bestComparison(item, predicted, dates)
            else {
                return ToolEvalOutcome(
                    item: item, answer: answer, toolCorrect: false, callExact: false, callTolerant: false,
                    falseFire: false, refusalLenient: nil, refusalStrict: nil, slots: [:], schemaValid: schemaValid)
            }
            return ToolEvalOutcome(
                item: item, answer: answer, toolCorrect: true, callExact: comparison.exact, callTolerant: comparison.tolerant,
                falseFire: false, refusalLenient: nil, refusalStrict: nil, slots: comparison.slots, schemaValid: schemaValid)
        case .noAction:
            return ToolEvalOutcome(
                item: item, answer: answer, toolCorrect: isNoAction, callExact: isNoAction, callTolerant: isNoAction,
                falseFire: !isNoAction, refusalLenient: nil, refusalStrict: nil, slots: [:], schemaValid: schemaValid)
        case .refuse:
            let split = splitMatch(item, real, dates)
            let lenient = isNoAction || split.tolerant
            let reasonOK = reason.map { (item.expect.reasons ?? []).contains($0.rawValue) } ?? false
            let strict = (isNoAction && reasonOK) || split.exact
            return ToolEvalOutcome(
                item: item, answer: answer, toolCorrect: lenient, callExact: strict, callTolerant: lenient,
                falseFire: false, refusalLenient: lenient, refusalStrict: strict, slots: [:], schemaValid: schemaValid)
        }
    }

    static func dateContext(_ item: ToolEvalCase) -> ToolArgumentMatcher.DateContext {
        ToolArgumentMatcher.DateContext(
            now: item.context.nowDate ?? Date(), timeZone: item.context.zone ?? .current, spoken: item.expect.whenSpoken ?? [],
            locale: Locale(identifier: item.context.locale))
    }

    /// The best argument comparison among acceptable calls with the predicted tool.
    private static func bestComparison(
        _ item: ToolEvalCase, _ predicted: ToolCall, _ dates: ToolArgumentMatcher.DateContext
    ) -> ToolArgumentMatcher.CallComparison? {
        let comparisons = item.expect.acceptableCalls.filter { $0.tool == predicted.tool }.map {
            ToolArgumentMatcher.compare(expected: $0, accept: item.expect.accept ?? [:], predicted: predicted, dates: dates)
        }
        return comparisons.max { rank($0) < rank($1) }
    }

    private static func rank(_ comparison: ToolArgumentMatcher.CallComparison) -> Int {
        (comparison.exact ? 2 : 0) + (comparison.tolerant ? 1 : 0)
    }

    /// Whether `predicted` is an acceptable one-call-per-intent split (tools paired one to one).
    private static func splitMatch(
        _ item: ToolEvalCase, _ predicted: [ToolCall], _ dates: ToolArgumentMatcher.DateContext
    ) -> (exact: Bool, tolerant: Bool) {
        guard let split = item.expect.split, !split.isEmpty, predicted.count == split.count else { return (false, false) }
        var remaining = predicted
        var exact = true
        for want in split {
            let scored = remaining.enumerated().filter { $0.element.tool == want.tool }.map {
                ($0.offset, ToolArgumentMatcher.compare(expected: want, predicted: $0.element, dates: dates))
            }
            guard let best = scored.max(by: { rank($0.1) < rank($1.1) }), best.1.tolerant else { return (false, false) }
            exact = exact && best.1.exact
            remaining.remove(at: best.0)
        }
        return (exact, true)
    }

    static func describe(_ call: ToolCall) -> String {
        let args = call.arguments.sorted { $0.key < $1.key }.map { key, value -> String in
            switch value {
            case .string(let text): "\(key)=\"\(text)\""
            case .integer(let number): "\(key)=\(number)"
            case .strings(let items): "\(key)=[\(items.joined(separator: ", "))]"
            }
        }
        return "\(call.tool)(\(args.joined(separator: " ")))"
    }
}

/// The aggregate numbers of one run.
struct ToolEvalSummary: Sendable {
    struct Group: Sendable {
        var count = 0
        var toolCorrect = 0
        var tolerant = 0
    }

    let total: Int
    let positives: Int
    let negatives: Int
    let refusals: Int
    let toolSelectAccuracy: Double
    let perToolMacroAccuracy: Double
    let callExactRate: Double
    let callTolerantRate: Double
    let argExactGivenTool: Double
    let argTolerantGivenTool: Double
    let slotTolerantAccuracy: Double
    let slotChecks: Int
    let falseFireRate: Double
    let falseFires: Int
    let missedCommandRate: Double
    let refusalLenient: Double
    let refusalStrict: Double
    let schemaValidity: Double
    let errors: Int
    /// Cases the model was asked about (extractor mode), and the false fires that would have acted
    /// without a card.
    let modelCalls: Int
    let falseFiresActingAtOnce: Int
    /// Right-tool commands that name no list or calendar, and how many answers named one anyway.
    let targetFreeCommands: Int
    let unaskedTargets: Int
    let latencyP50: Double
    let latencyP95: Double
    let toolNameP50: Double?
    let toolNameP95: Double?
    let byCategory: [(ToolEvalCategory, Group)]
    let byLocale: [(String, Group)]
    let byExpectedTool: [(String, Group)]

    init(_ outcomes: [ToolEvalOutcome]) {
        func rate(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }
        let positives = outcomes.filter { $0.item.expect.decision == .call }
        let negatives = outcomes.filter { $0.item.expect.decision == .noAction }
        let refusals = outcomes.filter { $0.item.expect.decision == .refuse }
        let rightTool = positives.filter(\.toolCorrect)
        let slotChecks = rightTool.flatMap(\.slots.values)
        total = outcomes.count
        self.positives = positives.count
        self.negatives = negatives.count
        self.refusals = refusals.count
        toolSelectAccuracy = rate(outcomes.filter(\.toolCorrect).count, outcomes.count)
        callExactRate = rate(positives.filter(\.callExact).count, positives.count)
        callTolerantRate = rate(positives.filter(\.callTolerant).count, positives.count)
        argExactGivenTool = rate(rightTool.filter(\.callExact).count, rightTool.count)
        argTolerantGivenTool = rate(rightTool.filter(\.callTolerant).count, rightTool.count)
        slotTolerantAccuracy = rate(slotChecks.filter(\.tolerant).count, slotChecks.count)
        self.slotChecks = slotChecks.count
        falseFires = negatives.filter(\.falseFire).count
        falseFireRate = rate(falseFires, negatives.count)
        missedCommandRate = rate(positives.filter { $0.answer.error != nil || $0.answer.calls.allSatisfy(\.isNoAction) }.count, positives.count)
        refusalLenient = rate(refusals.filter { $0.refusalLenient == true }.count, refusals.count)
        refusalStrict = rate(refusals.filter { $0.refusalStrict == true }.count, refusals.count)
        schemaValidity = rate(outcomes.filter(\.schemaValid).count, outcomes.count)
        errors = outcomes.filter { $0.answer.error != nil }.count
        modelCalls = outcomes.filter { $0.answer.modelCalled ?? true }.count
        falseFiresActingAtOnce = negatives.filter { $0.falseFire && $0.answer.actsAtOnce == true }.count
        targetFreeCommands = positives.filter(\.expectsNoTarget).count
        unaskedTargets = positives.filter(\.namesUnaskedTarget).count
        let latencies = outcomes.map(\.answer.latencyMs)
        latencyP50 = EvalMetrics.percentile(latencies, 0.5)
        latencyP95 = EvalMetrics.percentile(latencies, 0.95)
        let toolName = outcomes.compactMap(\.answer.timeToToolNameMs)
        toolNameP50 = toolName.isEmpty ? nil : EvalMetrics.percentile(toolName, 0.5)
        toolNameP95 = toolName.isEmpty ? nil : EvalMetrics.percentile(toolName, 0.95)
        byCategory = ToolEvalCategory.allCases.compactMap { category in
            let group = Self.group(outcomes.filter { $0.item.category == category })
            return group.count == 0 ? nil : (category, group)
        }
        byLocale = ["en_US", "en_IN"].map { locale in (locale, Self.group(outcomes.filter { $0.item.context.locale == locale })) }
        let tools = VoiceToolCatalog.names
        byExpectedTool = tools.compactMap { tool in
            let group = Self.group(outcomes.filter { $0.item.expect.tool == tool })
            return group.count == 0 ? nil : (tool, group)
        }
        perToolMacroAccuracy = byExpectedTool.isEmpty ? 0
            : byExpectedTool.map { rate($0.1.toolCorrect, $0.1.count) }.reduce(0, +) / Double(byExpectedTool.count)
    }

    private static func group(_ outcomes: [ToolEvalOutcome]) -> Group {
        Group(count: outcomes.count, toolCorrect: outcomes.filter(\.toolCorrect).count, tolerant: outcomes.filter(\.callTolerant).count)
    }
}
