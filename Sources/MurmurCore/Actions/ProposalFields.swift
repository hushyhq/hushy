import Foundation

/// Why a `propose_*` tool call was rejected, worded for the agent (it's returned as the tool
/// error so the agent can correct the call).
public struct ProposalValidationError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// The one set of field-level checks behind every `propose_*` tool (`propose_action`,
/// `propose_calendar_invite`, `propose_email_draft`, `propose_message`, `propose_issue`).
///
/// The MCP server (acknowledge-only) and the Assistant's stream parser (which turns a valid
/// call into data for a card) both go through the same `validate` of the same tool, and every
/// tool's `validate` is built from these helpers, so a proposal can never be acceptable on one
/// side of the bridge and not the other.
///
/// Every string is trimmed and stripped of control characters (newlines stay), capped in
/// length, and — for free text that ends up in an invite, email, message or issue — screened
/// for anything that looks like a credential or payment detail (`SensitiveContentScreen`).
public enum ProposalFields {
    // MARK: Limits (one place, so the MCP schema descriptions and the checks agree)

    public static let maxTitleLength = 200
    public static let maxNotesLength = 2_000
    public static let maxNameLength = 120
    public static let maxSubjectLength = 200
    public static let maxBodyLength = 10_000
    public static let maxMessageLength = 4_000
    public static let maxDescriptionLength = 8_000
    public static let maxLabelLength = 60
    public static let maxLabelCount = 20
    public static let maxRecipientCount = 50
    public static let maxAttendeeCount = 50
    public static let maxEmailLength = 254
    public static let maxEmailLocalPartLength = 64
    public static let maxHintLength = 120
    public static let maxIdentifierLength = 256
    public static let maxDateLength = 64

    public static let defaultDurationMinutes = 30
    public static let durationRange = 5...(24 * 60)
    /// A proposal more than a day in the past or five years out is almost certainly a mistake.
    public static let earliestOffset: TimeInterval = -24 * 3600
    public static let latestOffset: TimeInterval = 5 * 366 * 24 * 3600

    // MARK: Text

    /// A required trimmed string: control characters removed, length capped.
    public static func requiredText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String {
        guard let value = try optionalText(arguments, key, limit: limit) else {
            throw ProposalValidationError(message: "Missing string argument: \(key).")
        }
        return value
    }

    /// An optional trimmed string; nil when absent, null or blank. Rejects non-strings and
    /// anything over `limit` characters.
    public static func optionalText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard let string = raw as? String else { throw ProposalValidationError(message: "\(key) must be a string.") }
        let cleaned = clean(string)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= limit else {
            throw ProposalValidationError(message: "\(key) is too long (max \(limit) characters).")
        }
        return cleaned
    }

    /// Free text that will be carried into an invite, email, message or issue: the same as
    /// `requiredText`, plus the credential/payment screen.
    public static func requiredFreeText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String {
        let value = try requiredText(arguments, key, limit: limit)
        try screen(value, key)
        return value
    }

    /// Optional free text with the credential/payment screen.
    public static func optionalFreeText(_ arguments: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = try optionalText(arguments, key, limit: limit) else { return nil }
        try screen(value, key)
        return value
    }

    /// Rejects `value` if it looks like it carries a password, key, card number or similar.
    public static func screen(_ value: String, _ key: String) throws {
        if let finding = SensitiveContentScreen.finding(in: value) {
            throw ProposalValidationError(message: """
                \(key) looks like it contains \(finding.description). Hushy never carries passwords, \
                keys, card numbers or similar in a proposal; leave that out and try again.
                """)
        }
    }

    /// Control characters removed (newlines kept), whitespace trimmed.
    static func clean(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.filter {
            $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lists

    /// A list of strings under `key`: a JSON array of strings, or a single string. Each item is
    /// cleaned like `optionalText`; blank items are dropped; the count and item length are capped.
    public static func stringList(
        _ arguments: [String: Any], _ key: String, maxCount: Int, itemLimit: Int
    ) throws -> [String] {
        guard let raw = arguments[key], !(raw is NSNull) else { return [] }
        let items: [Any]
        if let array = raw as? [Any] {
            items = array
        } else if raw is String {
            items = [raw]
        } else {
            throw ProposalValidationError(message: "\(key) must be an array of strings.")
        }
        guard items.count <= maxCount else {
            throw ProposalValidationError(message: "\(key) has too many entries (max \(maxCount)).")
        }
        return try items.compactMap { item -> String? in
            guard let string = item as? String else {
                throw ProposalValidationError(message: "\(key) must contain only strings.")
            }
            let cleaned = clean(string)
            guard !cleaned.isEmpty else { return nil }
            guard cleaned.count <= itemLimit else {
                throw ProposalValidationError(message: "An entry in \(key) is too long (max \(itemLimit) characters).")
            }
            return cleaned
        }
    }

    // MARK: Email addresses

    /// A conservative address check: one `@`, a local part of the usual characters, a dotted
    /// domain of letters, digits and hyphens. Display names ("Dana <dana@example.com>") are not
    /// accepted here; callers that allow them split the name off first.
    public static func isValidEmail(_ text: String) -> Bool {
        guard text.count <= maxEmailLength, !text.contains(where: \.isWhitespace) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        guard !local.isEmpty, local.count <= maxEmailLocalPartLength,
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..")
        else { return false }
        guard local.unicodeScalars.allSatisfy({ Self.localPartCharacters.contains($0) }) else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ Self.isValidDomainLabel($0) }) else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    private static let localPartCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._%+-'"))

    private static func isValidDomainLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A list of email addresses under `key`, every one validated.
    public static func emailList(_ arguments: [String: Any], _ key: String, maxCount: Int) throws -> [String] {
        let items = try stringList(arguments, key, maxCount: maxCount, itemLimit: maxEmailLength)
        for item in items where !isValidEmail(item) {
            throw ProposalValidationError(message: "\(key) contains “\(clip(item, 60))”, which isn't an email address.")
        }
        return items
    }

    // MARK: Dates and durations

    /// An optional ISO-8601 date-time with offset, within the sane window around `now`.
    public static func date(_ arguments: [String: Any], _ key: String, now: Date) throws -> Date? {
        guard let text = try optionalText(arguments, key, limit: maxDateLength) else { return nil }
        guard let date = parseISO8601(text) else {
            throw ProposalValidationError(message: """
                \(key) “\(clip(text, 40))” isn't an ISO-8601 date and time with offset, e.g. 2026-09-27T15:00:00-07:00.
                """)
        }
        let offset = date.timeIntervalSince(now)
        guard offset >= earliestOffset else { throw ProposalValidationError(message: "\(key) is in the past.") }
        guard offset <= latestOffset else { throw ProposalValidationError(message: "\(key) is too far in the future.") }
        return date
    }

    /// A required ISO-8601 date-time with offset.
    public static func requiredDate(_ arguments: [String: Any], _ key: String, now: Date, purpose: String) throws -> Date {
        guard let date = try date(arguments, key, now: now) else {
            throw ProposalValidationError(message: "\(purpose) needs \(key): an ISO-8601 date and time with offset.")
        }
        return date
    }

    /// `durationMinutes`: a whole number within `durationRange`, or the default when absent.
    public static func durationMinutes(_ arguments: [String: Any], key: String = "durationMinutes") throws -> Int {
        guard let raw = arguments[key], !(raw is NSNull) else { return defaultDurationMinutes }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded()
        else { throw ProposalValidationError(message: "\(key) must be a whole number of minutes.") }
        let minutes = number.intValue
        guard durationRange.contains(minutes) else {
            throw ProposalValidationError(message: "\(key) must be between \(durationRange.lowerBound) and \(durationRange.upperBound).")
        }
        return minutes
    }

    /// Full date-time with an explicit offset or `Z`, with or without fractional seconds. A
    /// date without a time zone is rejected rather than guessed.
    public static func parseISO8601(_ text: String) -> Date? {
        let plain = isoFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = isoFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: text)
    }

    public static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }

    public static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
