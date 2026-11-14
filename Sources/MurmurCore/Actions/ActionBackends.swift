import Foundation

/// An identifier that lets a completed action be undone. Backend-specific string payload
/// (an `EKEvent`/`EKReminder` identifier for EventKit; `nil`/unsupported for Shortcuts, which
/// have no general undo — see docs/research/voice-actions.md §3, §4.1).
public struct ActionUndoToken: Sendable, Equatable {
    public let backendID: String
    public init(backendID: String) {
        self.backendID = backendID
    }
}

public enum ActionExecutionError: Error, Sendable, Equatable {
    /// What a named target is, for the line that says it was not found.
    public enum Target: String, Sendable, Equatable {
        case calendar, list, shortcut
    }

    /// Why a run may have started and cannot be confirmed either way.
    public enum UncertainReason: String, Sendable, Equatable {
        /// The run was stopped by Hushy's own time limit.
        case timedOut
        /// The run ended with an error after it had started.
        case didNotFinish
    }

    case permissionDenied(String)
    case notFound(String)
    /// A calendar, Reminders list or Shortcut the person named does not exist. Never replaced
    /// by a default: the action is refused and the line names what was not found.
    case targetNotFound(Target, String)
    /// A calendar event with no start time. It is never created "now".
    case missingStart
    /// The side effect may have started and Hushy cannot tell (a Shortcut that timed out or
    /// stopped partway). Never retried blindly.
    case mayHaveRun(UncertainReason)
    /// No installed app matched `heard` for sure, but these are the closest (best first, at most
    /// `AppNameMatcher.maxSuggestions`): the user picks one instead of meeting a dead end.
    case closestApps(heard: String, apps: [String])
    case backendFailed(String)
    case saveFailed
    case needsInput(String)
}

/// How a refused or failed action is treated by the card, History and Retry.
public enum ActionFailureKind: Sendable, Equatable {
    /// Nothing happened and trying again can work (access not granted yet, a link that failed).
    case failed
    /// Something may have happened. Retrying could do it twice, so Retry is never offered.
    case uncertain
    /// Refused before anything happened because a detail is missing or does not exist.
    /// Repeating the same action cannot succeed, so Retry is not offered either.
    case blocked
}

extension ActionExecutionError {
    public var failureKind: ActionFailureKind {
        switch self {
        case .mayHaveRun: .uncertain
        case .missingStart, .targetNotFound, .needsInput: .blocked
        case .permissionDenied, .notFound, .closestApps, .backendFailed, .saveFailed: .failed
        }
    }

    /// Fixed log vocabulary. Never put associated values here: they may contain the action's
    /// title, a target name, or a system error with private details.
    public var logStepAndReason: String {
        switch self {
        case .permissionDenied: "access: permission denied"
        case .targetNotFound(.calendar, _): "target lookup: calendar not found"
        case .targetNotFound(.list, _): "target lookup: list not found"
        case .targetNotFound(.shortcut, _): "target lookup: shortcut not found"
        case .saveFailed: "save: save failed"
        case .missingStart: "validation: start missing"
        case .notFound: "lookup: target not found"
        case .mayHaveRun(.timedOut): "run: timed out"
        case .mayHaveRun(.didNotFinish): "run: did not finish"
        case .closestApps: "lookup: ambiguous app"
        case .backendFailed: "backend: failed"
        case .needsInput: "validation: input needed"
        }
    }
}

public struct ActionExecutionResult: Sendable, Equatable {
    public let undoToken: ActionUndoToken?
    /// Where it landed when Hushy chose the place: the calendar or list used because none was
    /// named, or "your default browser" when the named one could not take the link. Shown on the
    /// done chip so no default is silent.
    public let placedIn: String?
    public init(undoToken: ActionUndoToken?, placedIn: String? = nil) {
        self.undoToken = undoToken
        self.placedIn = placedIn
    }
}

/// Calendar/Reminders backend, implemented for real by `EventKitActionBackend` (Murmur target,
/// since it needs `EventKit` + the app's TCC usage-description entries) and faked in tests by
/// `FakeCalendarBackend` below — the repository-pattern split every backend in this feature uses
/// so `ActionExecutor`'s confirmation/undo logic can be tested without ever touching a real
/// calendar or reminders list.
public protocol CalendarActionBackend: Sendable {
    /// Whether Calendar/Reminders access has already been granted. Never triggers the system
    /// prompt itself — see `requestAccess`.
    func hasAccess(for kind: ProposedAction.Kind) async -> Bool
    /// Requests full access (macOS 14+ `requestFullAccessToEvents`/`requestFullAccessToReminders`),
    /// showing the system TCC prompt on first use. Returns the granted state.
    func requestAccess(for kind: ProposedAction.Kind) async -> Bool
    /// Titles of the calendars (events) or lists (reminders) a new item can be saved to, so the
    /// executor can check a named one exists before anything is saved.
    func writableTargetNames(for kind: ProposedAction.Kind) async -> [String]
    /// Saves after the executor has accepted an existing grant or a successful request. Do not
    /// check authorization again here: the status read can lag the request result. Never saves
    /// an event without a start or swaps a named target for the default.
    func createEvent(_ action: ProposedAction) async throws -> ActionExecutionResult
    func createReminder(_ action: ProposedAction) async throws -> ActionExecutionResult
    /// Reverses a previously created event/reminder using its stored identifier. Called from the
    /// success toast's "Undo" affordance within the undo window (docs/research/voice-actions.md §4.1).
    func undo(_ token: ActionUndoToken, kind: ProposedAction.Kind) async throws
}

/// Shortcuts backend: runs a named Shortcut via `/usr/bin/shortcuts run`, implemented for real by
/// `ShortcutsActionBackend` and faked in tests by `FakeShortcutsBackend` — Shortcuts execution is
/// treated as irreversible by default (voice-actions.md §3), so there is no `undo` here.
public protocol ShortcutsActionBackend: Sendable {
    /// Names of Shortcuts currently installed (`shortcuts list`), used for fuzzy name matching
    /// and the "closest match" error-card affordance (voice-actions.md §4.2).
    func availableShortcuts() async -> [String]
    /// Runs `name` with optional `input`, returning combined stdout/stderr on success.
    func run(name: String, input: String?) async throws -> String
}

/// Opens apps and links (`ProposedAction.Kind.openLink`): `NSWorkspace` in the app
/// (`WorkspaceLinkBackend`), a recorder in tests (`FakeLinkBackend`). Navigation only; there is
/// no undo for a tab that opened, so `execute` returns no token for this kind.
public protocol LinkOpeningBackend: Sendable {
    /// Opens `url` in the default handler, or in `browser` when the user named one. Returns
    /// "your default browser" when a named browser could not be used and the default took the
    /// link instead, nil otherwise.
    @discardableResult
    func open(url: URL, browser: String?) async throws -> String?
    /// Opens or activates the app named `name`.
    func openApp(named name: String) async throws
}

/// The default when no link backend is wired: every open fails plainly rather than silently.
public struct NoLinkBackend: LinkOpeningBackend {
    public init() {}
    public func open(url: URL, browser: String?) async throws -> String? { throw ActionExecutionError.backendFailed("no link backend") }
    public func openApp(named name: String) async throws { throw ActionExecutionError.backendFailed("no link backend") }
}

// MARK: - Fakes (used by tests and, optionally, DEBUG previews — never real Calendar/Reminders/Shortcuts)

/// Records every open instead of opening anything.
public actor FakeLinkBackend: LinkOpeningBackend {
    public enum Opened: Sendable, Equatable {
        case url(URL, browser: String?)
        case app(String)
    }

    public private(set) var opened: [Opened] = []
    public var nextError: ActionExecutionError?

    public init() {}

    /// When set, an open that names a browser reports the default browser took it instead.
    public var fallsBackToDefaultBrowser = false

    public func open(url: URL, browser: String?) async throws -> String? {
        if let error = nextError { nextError = nil; throw error }
        opened.append(.url(url, browser: browser))
        return browser != nil && fallsBackToDefaultBrowser ? "your default browser" : nil
    }

    public func openApp(named name: String) async throws {
        if let error = nextError { nextError = nil; throw error }
        opened.append(.app(name))
    }

    public func setFallsBack(_ value: Bool) { fallsBackToDefaultBrowser = value }
    public func setNextError(_ error: ActionExecutionError?) { nextError = error }
}

/// In-memory fake used by tests: never touches a real calendar, always grants access unless told
/// not to, and records every created/undone item so tests can assert on exactly what would have
/// happened. Mirrors the shape of other in-repo fakes (e.g. `FakeDeviceAuthenticator`).
public actor FakeCalendarBackend: CalendarActionBackend {
    public struct CreatedItem: Sendable, Equatable {
        public let id: String
        public let action: ProposedAction
    }

    public private(set) var createdEvents: [CreatedItem] = []
    public private(set) var createdReminders: [CreatedItem] = []
    public private(set) var undone: [String] = []
    /// When set, the next `undo` throws this and removes nothing.
    public var nextUndoError: ActionExecutionError?
    public var eventsAccessGranted: Bool
    public var remindersAccessGranted: Bool
    private var eventRequestResult = true
    private var reminderRequestResult = true
    private var eventRequestUpdatesStatus = true
    private var reminderRequestUpdatesStatus = true
    /// The calendars and Reminders lists that exist in this fake, and the one used when none is named.
    public var calendarNames: [String] = ["Home", "Work"]
    public var listNames: [String] = ["Reminders", "Groceries"]
    public var defaultCalendarName = "Home"
    public var defaultListName = "Reminders"
    /// When set, the next `createEvent`/`createReminder` call throws this instead of succeeding.
    public var nextError: ActionExecutionError?
    public var createDelay: Duration?
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    public init(eventsAccessGranted: Bool = true, remindersAccessGranted: Bool = true) {
        self.eventsAccessGranted = eventsAccessGranted
        self.remindersAccessGranted = remindersAccessGranted
    }

    public func hasAccess(for kind: ProposedAction.Kind) async -> Bool {
        kind == .createReminder ? remindersAccessGranted : eventsAccessGranted
    }

    public func requestAccess(for kind: ProposedAction.Kind) async -> Bool {
        if kind == .createReminder {
            if reminderRequestResult && reminderRequestUpdatesStatus { remindersAccessGranted = true }
            return reminderRequestResult
        }
        if eventRequestResult && eventRequestUpdatesStatus { eventsAccessGranted = true }
        return eventRequestResult
    }

    public func setRequestResult(
        _ granted: Bool, for kind: ProposedAction.Kind, updatesStatus: Bool = true
    ) {
        if kind == .createReminder {
            reminderRequestResult = granted
            reminderRequestUpdatesStatus = updatesStatus
        } else {
            eventRequestResult = granted
            eventRequestUpdatesStatus = updatesStatus
        }
    }

    public func writableTargetNames(for kind: ProposedAction.Kind) async -> [String] {
        kind == .createReminder ? listNames : calendarNames
    }

    public func createEvent(_ action: ProposedAction) async throws -> ActionExecutionResult {
        if let delay = createDelay { try? await Task.sleep(for: delay) }
        await waitIfHeld()
        if let error = nextError { nextError = nil; throw error }
        let id = "fake-event-\(createdEvents.count + 1)"
        createdEvents.append(CreatedItem(id: id, action: action))
        return ActionExecutionResult(
            undoToken: ActionUndoToken(backendID: id), placedIn: action.calendarName ?? defaultCalendarName)
    }

    public func createReminder(_ action: ProposedAction) async throws -> ActionExecutionResult {
        if let delay = createDelay { try? await Task.sleep(for: delay) }
        await waitIfHeld()
        if let error = nextError { nextError = nil; throw error }
        let id = "fake-reminder-\(createdReminders.count + 1)"
        createdReminders.append(CreatedItem(id: id, action: action))
        return ActionExecutionResult(
            undoToken: ActionUndoToken(backendID: id), placedIn: action.listName ?? defaultListName)
    }

    /// Test hooks: an actor's stored properties can't be set from outside it.
    public func setNextError(_ error: ActionExecutionError?) { nextError = error }
    public func setNextUndoError(_ error: ActionExecutionError?) { nextUndoError = error }
    /// Makes each create take this long, to line up overlapping actions in tests.
    public func setCreateDelay(_ delay: Duration?) { createDelay = delay }

    /// Holds every create open until `release()`, so a test can overlap two actions without timing.
    public func holdCreates() { isHolding = true }
    public var heldCount: Int { held.count }
    public func release() {
        isHolding = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    private func waitIfHeld() async {
        guard isHolding else { return }
        await withCheckedContinuation { held.append($0) }
    }

    public func undo(_ token: ActionUndoToken, kind: ProposedAction.Kind) async throws {
        if let error = nextUndoError { nextUndoError = nil; throw error }
        undone.append(token.backendID)
        if kind == .createReminder {
            createdReminders.removeAll { $0.id == token.backendID }
        } else {
            createdEvents.removeAll { $0.id == token.backendID }
        }
    }
}

/// In-memory fake for Shortcuts: never spawns a real `/usr/bin/shortcuts` process. Tests
/// configure `installedShortcuts` and can inspect `runs` for exactly what would have executed.
public actor FakeShortcutsBackend: ShortcutsActionBackend {
    public struct Run: Sendable, Equatable {
        public let name: String
        public let input: String?
    }

    public var installedShortcuts: [String]
    public private(set) var runs: [Run] = []
    /// Every call to `run`, including ones that threw: what a retry would add to.
    public private(set) var attempts = 0
    public var nextError: ActionExecutionError?

    public init(installedShortcuts: [String] = []) {
        self.installedShortcuts = installedShortcuts
    }

    public func availableShortcuts() async -> [String] { installedShortcuts }

    public func setNextError(_ error: ActionExecutionError?) { nextError = error }

    public func run(name: String, input: String?) async throws -> String {
        attempts += 1
        if let error = nextError { nextError = nil; throw error }
        guard installedShortcuts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ActionExecutionError.notFound(name)
        }
        runs.append(Run(name: name, input: input))
        return "ok"
    }
}
