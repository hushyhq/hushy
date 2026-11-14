import Foundation

/// Executes one confirmed `ProposedAction` against the right backend, returning an undo token
/// when the backend supports one. Confirmation itself (the ✓/Edit/✕ card) lives in the UI layer
/// (Murmur target's Pill); this type is the pure "given a confirmed action, make it happen"
/// step, kept in MurmurCore so it can be unit-tested against the fakes in `ActionBackends.swift`
/// without any UI, EventKit, or subprocess dependency.
public actor ActionExecutor {
    private let calendar: any CalendarActionBackend
    private let shortcuts: any ShortcutsActionBackend
    private let links: any LinkOpeningBackend

    public init(
        calendar: any CalendarActionBackend, shortcuts: any ShortcutsActionBackend,
        links: any LinkOpeningBackend = NoLinkBackend()
    ) {
        self.calendar = calendar
        self.shortcuts = shortcuts
        self.links = links
    }

    /// Executes `action`, requesting backend permission first if it hasn't been granted yet
    /// (voice-actions.md: "request Calendar/Reminders lazily on first voice-action attempt").
    ///
    /// Revalidates immediately before the side effect, whatever put the action here (a card row
    /// the person confirmed, a retry, the Assistant): an event has a start, and a calendar or
    /// list the person named exists. Nothing is guessed. A missing start or an unknown name
    /// throws before anything is saved.
    public func execute(_ action: ProposedAction) async throws -> ActionExecutionResult {
        if let problem = ActionPreflight.problem(in: action) { throw problem }
        switch action.kind {
        case .createEvent:
            try await ensureAccess(for: .createEvent, named: "Calendar")
            try await requireNamedTargetExists(for: action)
            return try await calendar.createEvent(action)
        case .createReminder:
            try await ensureAccess(for: .createReminder, named: "Reminders")
            try await requireNamedTargetExists(for: action)
            return try await calendar.createReminder(action)
        case .runShortcut:
            guard let name = action.shortcutName else {
                throw ActionExecutionError.backendFailed("no shortcut name")
            }
            let available = await shortcuts.availableShortcuts()
            guard let match = ShortcutMatcher.bestMatch(spoken: name, available: available) else {
                throw ActionExecutionError.targetNotFound(.shortcut, name)
            }
            // A Shortcut is the person's own automation: Hushy cannot see what it does, cannot
            // undo it, and does not run it a second time on its own. A timeout or a non-zero exit
            // comes back as `.mayHaveRun` (see `ShortcutRunOutcome`), never as a plain failure.
            _ = try await shortcuts.run(name: match, input: action.shortcutInput)
            return ActionExecutionResult(undoToken: nil)
        case .openLink:
            // Navigation only. A URL was built by code (`DeepLinkBuilder`, `AIHandoffLink`) or
            // screened (`SafeURLPolicy`) before it reached the action; the spoken words never
            // supply a host. An opened tab can't be closed by Hushy, so there is no undo token.
            let placedIn = try await openLink(action)
            return ActionExecutionResult(undoToken: nil, placedIn: placedIn)
        }
    }

    private func ensureAccess(for kind: ProposedAction.Kind, named what: String) async throws {
        if await !calendar.hasAccess(for: kind) {
            guard await calendar.requestAccess(for: kind) else {
                throw ActionExecutionError.permissionDenied(what)
            }
        }
    }

    /// A calendar or list the person named must exist. Not named: the default is fine.
    private func requireNamedTargetExists(for action: ProposedAction) async throws {
        guard let named = ActionPreflight.namedTarget(of: action) else { return }
        let available = await calendar.writableTargetNames(for: action.kind)
        guard ActionPreflight.resolves(named.name, among: available) else {
            throw ActionExecutionError.targetNotFound(named.target, named.name)
        }
    }

    /// The app named in `appName` first; a `url` next (an AI service's site when its app isn't
    /// installed, or a plain link). An action naming neither (older records) opens its title.
    private func openLink(_ action: ProposedAction) async throws -> String? {
        if let appName = action.appName {
            do {
                try await links.openApp(named: appName)
                return nil
            } catch ActionExecutionError.notFound where action.url != nil {
                // Not installed: the site is the same service.
            } catch ActionExecutionError.closestApps where action.url != nil {
                // Only look-alikes installed: an AI service's site beats guessing between them.
            }
        }
        guard let raw = action.url else {
            if action.appName == nil { try await links.openApp(named: action.title) }
            return nil
        }
        guard let url = URL(string: raw), url.scheme == "https" || url.scheme == "slack" else {
            throw ActionExecutionError.backendFailed("not a safe link")
        }
        return try await links.open(url: url, browser: action.location)
    }

    /// Undoes a previously executed Calendar/Reminders action. A no-op (throws) for Shortcuts,
    /// since `execute` never returns an undo token for that backend.
    public func undo(_ token: ActionUndoToken, kind: ProposedAction.Kind) async throws {
        try await calendar.undo(token, kind: kind)
    }

    /// Candidate names for a Shortcut the user asked to run but that isn't installed, so the
    /// confirmation card can offer them instead of a hard failure (voice-actions.md §4.2).
    public func suggestedShortcutNames(for spoken: String, limit: Int = 3) async -> [String] {
        let available = await shortcuts.availableShortcuts()
        return Array(ShortcutMatcher.rank(spoken: spoken, available: available).prefix(limit))
    }
}
