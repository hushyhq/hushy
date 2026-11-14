import Foundation

/// Why Hushy could not tell whether a text field had focus, or could not read the field after the
/// paste or a copy-only decision: one log line with no dictated words.
///
/// It exists so the next report can be diagnosed from the log alone. It names the query that
/// answered and the error of the one that did not, the kind of element seen, the app and the app
/// category. It never carries the dictated text, a window title or a field's value: every field is
/// a fixed word, a number, or an identifier cut down to letters and digits (`identifier`,
/// `bundleToken`).
public struct PasteDiagnosis: Sendable, Equatable {
    /// Which focused-element query gave the element Hushy used at key-down.
    public enum Query: String, Sendable, Equatable {
        /// The app's own focused element.
        case app
        /// The system-wide focused element, asked only after the app's query gave nothing.
        case system
        /// Neither gave an element.
        case none
    }

    /// How the system-wide query went.
    public enum SystemQuery: Sendable, Equatable {
        /// Not asked: the app's query answered.
        case skipped
        case ok
        /// It answered with an element of another process, which is never used.
        case otherProcess
        case error(Int32)

        var token: String {
            switch self {
            case .skipped: "skipped"
            case .ok: "ok"
            case .otherProcess: "other-pid"
            case .error(let code): "err:\(PasteDiagnosis.errorName(code))"
            }
        }
    }

    /// A yes/no accessibility read, or the error that stopped it.
    public enum Flag: Sendable, Equatable {
        case yes, no
        case error(Int32)

        var token: String {
            switch self {
            case .yes: "1"
            case .no: "0"
            case .error(let code): "err:\(PasteDiagnosis.errorName(code))"
            }
        }
    }

    /// How one read of the field for the landing check ended.
    public enum Probe: Sendable, Equatable {
        /// No read happened (the delivery ended before it).
        case notRead
        /// A count or a caret position was read.
        case ok
        /// The target was no longer the key-down target.
        case targetMoved
        /// There was no element to read.
        case noElement
        /// The focused field is not the one the read before ⌘V looked at (`LandingPin`).
        case otherElement
        /// The element may be a password field, so it is not read: positively secure (nil), or the
        /// role or subrole read failed with this error.
        case security(Int32?)
        /// The character count could not be read (and no caret position either).
        case count(Int32)
        /// The value is not text.
        case valueType
        /// The value is longer than Hushy counts.
        case valueLong

        var token: String {
            switch self {
            case .notRead: "none"
            case .ok: "ok"
            case .targetMoved: "verdict"
            case .noElement: "no-element"
            case .otherElement: "other-element"
            case .security(let code): "security:\(code.map(PasteDiagnosis.errorName) ?? "secure")"
            case .count(let code): "count:\(PasteDiagnosis.errorName(code))"
            case .valueType: "value-type"
            case .valueLong: "value-long"
            }
        }
    }

    /// What the look at focus at key-down found.
    public struct Focus: Sendable, Equatable {
        public var query: Query
        /// The error of the app's own focused-element query (0 when it answered).
        public var appError: Int32
        public var system: SystemQuery
        public var role: String?
        public var subrole: String?
        public var settable: Flag
        public var range: Flag
        public var positivelyNoWindow: Bool

        public init(query: Query, appError: Int32, system: SystemQuery, role: String?, subrole: String?,
                    settable: Flag, range: Flag, positivelyNoWindow: Bool = false) {
            self.query = query
            self.appError = appError
            self.system = system
            self.role = role
            self.subrole = subrole
            self.settable = settable
            self.range = range
            self.positivelyNoWindow = positivelyNoWindow
        }

        /// Nothing was focused and nothing was asked beyond the app.
        public static let nothing = Focus(query: .none, appError: 0, system: .skipped, role: nil, subrole: nil,
                                          settable: .no, range: .no)
    }

    public var bundleID: String?
    /// Hushy's app category (`AppCategory.rawValue`).
    public var category: String
    public var answer: FocusAnswer
    public var focus: Focus
    /// A field found at paste time replaced what key-down saw (`FocusRefresh`). One word in the
    /// line, `late-field`, for both cases; `role` tells them apart: `none` when key-down saw
    /// nothing, the container's role when it saw a container.
    public var adopted: Bool
    public var before: Probe
    public var after: Probe
    public var signal: LandingSignal?

    public init(bundleID: String?, category: String, answer: FocusAnswer = .unknown, focus: Focus, adopted: Bool, before: Probe, after: Probe,
                signal: LandingSignal?) {
        self.bundleID = bundleID
        self.category = category
        self.answer = answer
        self.focus = focus
        self.adopted = adopted
        self.before = before
        self.after = after
        self.signal = signal
    }

    /// The log line includes the key-down answer and only fixed facts or sanitized identifiers.
    public var line: String {
        [
            "paste-diagnosis",
            "app=\(Self.bundleToken(bundleID))",
            "category=\(Self.identifier(category))",
            "focus=\(answer.rawValue)",
            "query=\(focus.query.rawValue)",
            "app-err=\(Self.errorName(focus.appError))",
            "sys-err=\(focus.system.token)",
            "role=\(Self.identifier(focus.role))",
            "subrole=\(Self.identifier(focus.subrole))",
            "settable=\(focus.settable.token)",
            "range=\(focus.range.token)",
            "no-window=\(focus.positivelyNoWindow ? "1" : "0")",
            "adopted=\(adopted ? "late-field" : "no")",
            "before=\(before.token)",
            "after=\(after.token)",
            "signal=\(signal?.rawValue ?? "none")",
        ].joined(separator: " ")
    }

    // MARK: Nothing free-form

    /// The longest an identifier is written.
    public static let tokenLimit = 40

    /// A role, subrole or category as the line writes it: ASCII letters and digits only, at most
    /// `tokenLimit` of them. An app may report any string as a role, so nothing else passes.
    public static func identifier(_ raw: String?) -> String {
        token(raw, alsoAllowed: "")
    }

    /// A bundle identifier: letters, digits, dots and hyphens, at most `tokenLimit` characters.
    public static func bundleToken(_ raw: String?) -> String {
        token(raw, alsoAllowed: ".-")
    }

    private static func token(_ raw: String?, alsoAllowed: String) -> String {
        guard let raw, !raw.isEmpty else { return "none" }
        let kept = raw.unicodeScalars.filter { scalar in
            guard scalar.isASCII else { return false }
            let character = Character(scalar)
            return character.isLetter || character.isNumber || alsoAllowed.unicodeScalars.contains(scalar)
        }
        guard !kept.isEmpty else { return "other" }
        return String(String.UnicodeScalarView(kept.prefix(tokenLimit)))
    }

    /// An accessibility error by name (`AXError`); a code this does not know keeps its number.
    public static func errorName(_ code: Int32) -> String {
        errorNames[code] ?? String(code)
    }

    private static let errorNames: [Int32: String] = [
        0: "ok", -25200: "failure", -25201: "illegal-argument", -25202: "invalid-element",
        -25203: "invalid-observer", -25204: "cannot-complete", -25205: "unsupported",
        -25206: "action-unsupported", -25207: "notification-unsupported", -25208: "not-implemented",
        -25209: "already-registered", -25210: "not-registered", -25211: "api-disabled",
        -25212: "no-value", -25213: "parameterized-unsupported", -25214: "not-enough-precision",
    ]
}

/// The reads of the field made for one landing check, as the diagnosis line reports them: how the
/// read before ⌘V ended, how the last read after it ended, and which signal the two show.
public struct LandingReadLog: Sendable, Equatable {
    private var first: (probe: LandingProbe?, status: PasteDiagnosis.Probe)?
    private var last: (probe: LandingProbe?, status: PasteDiagnosis.Probe)?

    public init() {}

    /// The first call is the read before ⌘V; every later one is a read after it.
    public mutating func record(_ probe: LandingProbe?, _ status: PasteDiagnosis.Probe) {
        if first == nil { first = (probe, status) } else { last = (probe, status) }
    }

    public var before: PasteDiagnosis.Probe { first?.status ?? .notRead }
    public var after: PasteDiagnosis.Probe { last?.status ?? .notRead }

    public func signal(pasted: PastedText) -> LandingSignal? {
        guard let before = first?.probe, let after = last?.probe else { return nil }
        return LandingEvidence.signal(before: before, after: after, pasted: pasted)
    }

    public static func == (lhs: LandingReadLog, rhs: LandingReadLog) -> Bool {
        lhs.first?.probe == rhs.first?.probe && lhs.first?.status == rhs.first?.status
            && lhs.last?.probe == rhs.last?.probe && lhs.last?.status == rhs.last?.status
    }
}
