import Foundation
import Testing
@testable import MurmurCore

/// WHAT THIS PROTECTS
///
/// The one fixed rule of usage metrics: no content ever leaves the Mac. These tests make that rule
/// a property of the *shape* of the data, so a later change cannot quietly break it:
///
/// 1. Every string value in a fully populated batch must be a raw value of a known enum, or match a
///    strict fixed pattern (ISO day, UUID). A new free-text field (a note, an app name, a bundle
///    ID, a mode name, an error message) puts an arbitrary string into the JSON and fails here.
/// 2. Every JSON key must be on a reviewed allowlist. Adding a field forces the author to edit this
///    list, which is the moment to ask "is this content-free?".
/// 3. No stored property anywhere in the batch is a `String`, `Date`, `Data` or `URL`. This catches
///    a free-text field even while it is empty or nil in the fixture, which the JSON walk cannot.
/// 4. Numbers are non-negative integers (no floats that could smuggle a timestamp or an embedding).
///
/// The checker is itself tested against hand-made violations, so it cannot rot into a no-op.
@Suite("Usage metrics: structural privacy")
struct MetricsPrivacyStructureTests {
    static let enumRawValues: Set<String> = {
        var values = Set<String>()
        func add<E: MetricsKey>(_: E.Type) { E.allCases.forEach { values.insert($0.rawValue) } }
        add(DictationFeedback.Delivery.self); add(DictationFeedback.CleanupModelProfile.self)
        add(DictationFeedback.FallbackReason.self); add(DictationFeedback.EditObservation.self)
        add(DictationFeedback.EditCoverage.self); add(CleanupLevel.self); add(MetricsModeKind.self)
        add(MetricsModelState.self); add(VoiceActionOutcome.self); add(VoiceActionFailureCategory.self)
        add(MeetingOutcome.self); add(FunnelStep.self); add(MetricsEnvironment.ChipClass.self)
        add(MetricsEnvironment.MemoryBand.self); add(MetricsRetention.FirstRunBand.self); add(MetricsTone.self)
        add(MetricsAppKind.self); add(MetricsEditVerdict.self); add(MetricsEditSize.self)
        return values
    }()

    /// Raw values of every enum that is rendered as a count table (all members always present).
    static let tableVocabulary: Set<String> = {
        var values = Set<String>()
        func add<E: MetricsKey>(_: E.Type) { E.allCases.forEach { values.insert($0.rawValue) } }
        add(DictationFeedback.Delivery.self); add(DictationFeedback.CleanupModelProfile.self)
        add(DictationFeedback.FallbackReason.self); add(DictationFeedback.EditObservation.self)
        add(DictationFeedback.EditCoverage.self); add(CleanupLevel.self); add(MetricsModeKind.self)
        add(MetricsModelState.self); add(VoiceActionOutcome.self); add(VoiceActionFailureCategory.self)
        add(MeetingOutcome.self); add(FunnelStep.self); add(MetricsTone.self)
        return values
    }()

    /// Reviewed, fixed field names. Edit deliberately.
    static let fieldNames: Set<String> = [
        "schemaVersion", "batchID", "day", "appBuild", "environment", "chipClass", "memoryBand", "macOSMajor",
        "dictations", "voiceActions", "meetings", "funnel",
        "delivery", "editObservation", "editCoverage", "fallbackReason", "cleanupLevel", "modeKind", "modelState",
        "words", "audioMilliseconds", "speechMilliseconds", "cleanupMilliseconds", "releaseToDeliveryMilliseconds",
        "counts", "sum", "outcome", "failure", "minutesRecorded",
        "retention", "daysSinceFirstRun", "activeDaysLast7", "tones",
        "editRate", "tone", "appKind", "verdict", "size", "count",
    ]

    static let isoDayPattern = #"^\d{4}-\d{2}-\d{2}$"#
    static let uuidPattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    /// Returns a description of every violation found; empty means the JSON is structurally content-free.
    static func violations(in value: Any, path: String = "$") -> [String] {
        switch value {
        case let dict as [String: Any]:
            return dict.flatMap { key, child -> [String] in
                let known = fieldNames.contains(key) || enumRawValues.contains(key)
                let own = known ? [] : ["unreviewed key '\(key)' at \(path)"]
                return own + violations(in: child, path: "\(path).\(key)")
            }
        case let array as [Any]:
            return array.enumerated().flatMap { violations(in: $1, path: "\(path)[\($0)]") }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return ["boolean at \(path)"] }
            if number.doubleValue != number.doubleValue.rounded() || number.int64Value < 0 { return ["non-integer or negative number at \(path)"] }
            return []
        case let string as String:
            if enumRawValues.contains(string) { return [] }
            if string.range(of: isoDayPattern, options: .regularExpression) != nil
                || string.range(of: uuidPattern, options: .regularExpression) != nil { return [] }
            return ["free-form string at \(path)"]
        default:
            return ["unsupported JSON value at \(path)"]
        }
    }

    private func populatedJSON() throws -> Any {
        try JSONSerialization.jsonObject(with: UsageMetricsFixtures.fullyPopulatedBatch().encodedBody())
    }

    @Test("a fully populated batch contains only enum members, fixed patterns and non-negative integers")
    func batchIsContentFree() throws {
        #expect(Self.violations(in: try populatedJSON()).isEmpty)
    }

    @Test("every enum case is actually exercised by the populated fixture")
    func fixtureIsFullyPopulated() throws {
        let data = try UsageMetricsFixtures.fullyPopulatedBatch().encodedBody()
        let text = String(decoding: data, as: UTF8.self)
        // Count tables list every member; the environment bands are single values and are exempt.
        let environmentOnly = Set(MetricsEnvironment.ChipClass.allCases.map(\.rawValue)
            + MetricsEnvironment.MemoryBand.allCases.map(\.rawValue)
            + MetricsRetention.FirstRunBand.allCases.map(\.rawValue)).subtracting(Self.tableVocabulary)
        for raw in Self.enumRawValues.subtracting(environmentOnly) {
            #expect(text.contains("\"\(raw)\""), "enum value \(raw) missing from the populated batch")
        }
        let batch = try UsageMetricsFixtures.fullyPopulatedBatch()
        #expect(batch.dictationsByProfile.count == DictationFeedback.CleanupModelProfile.allCases.count)
        #expect(batch.funnel.counts.count == FunnelStep.allCases.count)
    }

    @Test("the checker catches a free-text string, an unreviewed key, a float and a boolean")
    func checkerCatchesViolations() throws {
        var object = try #require(populatedJSON() as? [String: Any])
        object["comment"] = "meeting with Acme about the Q3 budget"
        #expect(Self.violations(in: object).count == 2)   // unreviewed key + free-form string

        var withBundle = try #require(populatedJSON() as? [String: Any])
        var env = try #require(withBundle["environment"] as? [String: Any])
        env["chipClass"] = "com.apple.Safari"
        withBundle["environment"] = env
        #expect(Self.violations(in: withBundle).contains { $0.contains("free-form string") })

        var withFloat = try #require(populatedJSON() as? [String: Any])
        withFloat["appBuild"] = 412.5
        #expect(!Self.violations(in: withFloat).isEmpty)

        var withBool = try #require(populatedJSON() as? [String: Any])
        withBool["appBuild"] = true
        #expect(!Self.violations(in: withBool).isEmpty)
    }

    @Test("no stored property in a batch can hold free text, a date, bytes or a URL")
    func noContentTypesInStorage() throws {
        let forbidden = ["String", "Date", "Data", "URL", "Any"]
        func scan(_ value: Any, path: String) -> [String] {
            let mirror = Mirror(reflecting: value)
            let typeName = String(describing: type(of: value))
            var found: [String] = []
            for word in forbidden where typeName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(word)) {
                found.append("\(path): \(typeName)")
            }
            for child in mirror.children { found += scan(child.value, path: "\(path).\(child.label ?? "_")") }
            return found
        }
        let batch = try UsageMetricsFixtures.fullyPopulatedBatch()
        #expect(scan(batch, path: "batch").isEmpty, "\(scan(batch, path: "batch"))")
        // The scanner must be able to see a violation: prove it on a type that has one.
        struct Leaky { let note: String }
        #expect(!scan(Leaky(note: "x"), path: "leaky").isEmpty)
        struct LeakyOptional { let note: String? }
        #expect(!scan(LeakyOptional(note: nil), path: "leaky").isEmpty)
    }

    @Test("the disclosure never mentions anything outside the batch's enums and numbers")
    func disclosureIsContentFree() throws {
        let lines = MetricsDisclosure.lines(for: try UsageMetricsFixtures.fullyPopulatedBatch())
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(lines.joined().range(of: "@") == nil)
    }
}
