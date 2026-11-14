import AppKit
import ApplicationServices
import MurmurCore

/// The app and field the user is dictating into, captured once at key-down.
struct FocusTarget: Equatable {
    let bundleID: String?
    let appName: String?
    let processID: pid_t?
    var answer: FocusAnswer
    var hasTextInput: Bool { answer != .noField }
    /// Title of the focused window, read only for browsers so we can tell Gmail from Slack.
    var windowTitle: String? = nil
    /// Published after the detached terminal look. Shared with the session so cleanup and saved category agree.
    var terminalContext: WindowContextBox? = nil
    /// AX proxy for the field that had focus when recording began. Kept only for the
    /// in-memory session and compared with the current focused element before dispatch.
    fileprivate var focusedElement: AXUIElement?
    /// AX proxy for the focused window at key-down: the fallback identity when the app exposed
    /// no focused field (Electron before its AX tree settles, some terminals).
    fileprivate var focusedWindow: AXUIElement? = nil
    fileprivate var hasStableFocusIdentity: Bool
    /// The key-down field positively read as a password field (read once, at key-down).
    fileprivate var fieldIsSecure = false
    /// The element came from the system-wide focus query (the app's own gave nothing), so every
    /// later check asks it too and resolves focus the way key-down did.
    fileprivate var usesSystemQuery = false
    /// Stops the system-wide query being asked again for this target once it has timed out.
    fileprivate var systemGate: SystemQueryGate? = nil
    /// What the look at focus at key-down found, for the diagnosis log line. Roles and error
    /// codes only: no text, no title, no value.
    private(set) var keyDownFocus = PasteDiagnosis.Focus.nothing
    /// The numbers of the key-down field (count, selection), read once at key-down and only for a known field in a
    /// watched app (`FieldWatch`). It is the "before" of the second look at a paste, so no read is made between
    /// cleanup and ⌘V.
    private(set) var fieldBaseline: LandingProbe? = nil
    /// A field found at paste time replaced what key-down saw (`refreshedForDelivery`): either of
    /// its two cases, nothing at key-down or a container at key-down.
    private(set) var adoptedLateField = false
    /// The website the person placed on a tone that this browser tab is (its key), read once at key-down; nil
    /// elsewhere, and when no website is placed (`WebPageSite`). No address or title is kept here.
    var site: String? = nil
    /// How that look went, for the key-down log line; nil when there was none.
    private(set) var siteLookup: WebPageSite.Lookup? = nil

    static func == (lhs: FocusTarget, rhs: FocusTarget) -> Bool {
        guard lhs.bundleID == rhs.bundleID, lhs.processID == rhs.processID,
              lhs.answer == rhs.answer,
              lhs.hasStableFocusIdentity == rhs.hasStableFocusIdentity else { return false }
        return switch (lhs.focusedElement, rhs.focusedElement) {
        case (nil, nil): true
        case (let left?, let right?): CFEqual(left, right)
        default: false
        }
    }

    #if DEBUG
    /// No app and no field, for tests: a delivery to it can never paste anywhere. (Not `none`,
    /// which `Optional.none` would shadow wherever a `FocusTarget?` is expected.)
    static var detachedForTests: FocusTarget {
        FocusTarget(bundleID: nil, appName: nil, processID: nil, answer: .noField, focusedElement: nil,
                    hasStableFocusIdentity: false)
    }

    /// A text field in no app, for tests that pass delivery their own focus read: it pastes only where they say.
    static var fieldForTests: FocusTarget {
        FocusTarget(bundleID: nil, appName: nil, processID: nil, answer: .field, focusedElement: nil,
                    hasStableFocusIdentity: false)
    }

    /// A known field with no Accessibility element behind it, for tests: the guard and the reads of it are
    /// scripted through `TextInserter.FieldAccess`. `baseline` is the key-down read.
    static func scriptedField(baseline: LandingProbe?) -> FocusTarget {
        FocusTarget(bundleID: "app.hushy.tests.field", appName: nil, processID: nil, answer: .field, focusedElement: nil,
                    hasStableFocusIdentity: false, fieldBaseline: baseline)
    }
    #endif

    /// - Parameter sites: the websites placed on a tone (`ToneSettings.siteMatcher`); nil reads no address.
    /// - Parameter forDictation: true only for the key-down target of a dictation, the one paste that is looked at
    ///   again (`FieldWatch`); the baseline read is made for no other caller.
    @MainActor
    static func current(sites: WebsiteMatcher? = nil, forDictation: Bool = false) -> FocusTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let reader = AXFocusReader(asksSystem: true)
        let query = app.map { reader.focusQuery(processID: $0.processIdentifier) }
        let element = query?.element
        let window = app.flatMap { reader.focusedWindow(processID: $0.processIdentifier) }
        let noWindow = element == nil && app.map { reader.positivelyHasNoWindows(processID: $0.processIdentifier) } == true
        let facts = Self.facts(app: app, focused: element, positivelyNoWindow: noWindow)
        let security = element.map { reader.security($0) }
        let baseline = FieldWatch.baseline(answer: facts.answer, bundleID: app?.bundleIdentifier, forDictation: forDictation) {
            element.flatMap { security == .notSecure ? Self.keyDownProbe(of: $0, selection: facts.selection) : nil }
        }
        let isBrowser = AppCategory.isBrowser(app?.bundleIdentifier)
        let windowTitle = isBrowser ? window.flatMap(Self.title) : nil
        let siteLookup = isBrowser ? sites.map { WebPageSite.lookup($0, title: windowTitle, window: window, focused: element) } : nil
        return FocusTarget(
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            processID: app?.processIdentifier,
            answer: facts.answer,
            windowTitle: windowTitle,
            focusedElement: element,
            focusedWindow: window,
            hasStableFocusIdentity: element != nil,
            fieldIsSecure: security == .secure,
            usesSystemQuery: query?.source == .system,
            systemGate: SystemQueryGate(),
            keyDownFocus: PasteDiagnosis.Focus(
                query: query?.source ?? .none, appError: (query?.appError ?? .success).rawValue,
                system: query?.system ?? .skipped, role: facts.role, subrole: facts.subrole,
                settable: facts.settable, range: facts.range, positivelyNoWindow: noWindow),
            fieldBaseline: baseline,
            site: siteLookup?.key, siteLookup: siteLookup)
    }

    /// What `TargetGuard` compares live focus against.
    var bound: BoundFocus<AXUIElement> {
        BoundFocus(processID: processID, bundleID: bundleID,
                   field: hasStableFocusIdentity ? focusedElement : nil, window: focusedWindow,
                   fieldIsSecure: fieldIsSecure)
    }

    /// Re-reads live focus and compares it with the key-down target: app, then exact field
    /// (or, when the app exposed no field, its window), plus the fail-closed secure-field check.
    /// Window *title* is intentionally metadata only: browser tabs retitle while keeping the field.
    @MainActor
    func verdict() -> TargetVerdict {
        TargetGuard.check(bound, reader: AXFocusReader(asksSystem: usesSystemQuery, systemGate: systemGate))
    }

    /// The same check with every read bounded by `budget`: a slow or hung app answers "could not tell", which a
    /// caller that only looks (the second look at a paste) treats as nothing to report.
    @MainActor
    func verdict(budget: AXReadBudget) -> TargetVerdict {
        TargetGuard.check(bound, reader: AXFocusReader(asksSystem: usesSystemQuery, budget: budget, systemGate: systemGate))
    }

    /// True only when a paste would land in the key-down field. Used by `paste last` and voice
    /// actions, which bind to the focus at the moment they run.
    @MainActor
    func stillOwnsFocus() -> Bool {
        hasTextInput && verdict() == .unchanged
    }

    private static func title(_ window: AXUIElement) -> String? {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    /// The kind of app we're typing into, including web apps inside browsers.
    var category: AppCategory {
        terminalContext?.isAgentPrompt == true ? .aiPrompts
            : AppCategory.classify(bundleID: bundleID, windowTitle: windowTitle)
    }

    /// The exact text field captured at dictation start. Edit observation uses this reference
    /// after delivery instead of re-reading whichever field happens to have focus then.
    var editObservationElement: AXUIElement? { focusedElement }

    /// Electron and Chromium apps (Slack, VS Code, Claude, Notion…) only build their
    /// accessibility tree when asked. Call this when dictation starts so the tree exists
    /// by the time we check for a text field.
    static func exposeAccessibility(of app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // That attribute is Electron's. Chrome, Brave, Edge and Arc ignore it and switch their tree
        // on when a tool reads the application's role, so ask for it; the answer is not used.
        AXUIElementSetMessagingTimeout(element, AXBounds.readTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    }

    /// What one focused element says about itself: the answer, and the facts behind it.
    private struct Facts {
        let answer: FocusAnswer
        var role: String?
        var subrole: String?
        var settable = PasteDiagnosis.Flag.no
        var range = PasteDiagnosis.Flag.no
        /// The selection the range read already returned, so the key-down baseline costs no second read of it.
        var selection: CFRange?
    }

    /// `budget`, when given, is asked before each of the four reads; a look that runs out of
    /// time answers `unknown`, which adopts nothing.
    @MainActor
    private static func facts(app: NSRunningApplication?, focused: AXUIElement?,
                              positivelyNoWindow: Bool = false, budget: AXReadBudget? = nil) -> Facts {
        let ownTextView: Bool? = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? NSApp.keyWindow.map { $0.firstResponder is NSTextView } : nil
        guard let focused else {
            return Facts(answer: FocusAnswer.classify(role: nil, subrole: nil, valueSettable: false,
                                                      hasSelectedTextRange: false, bundleID: app?.bundleIdentifier,
                                                      ownWindowTextView: ownTextView,
                                                      positivelyNoWindow: positivelyNoWindow))
        }
        let outOfTime = Facts(answer: .unknown)
        func spent() -> Bool { budget?.isSpent == true }
        guard !spent() else { return outOfTime }
        var settable: DarwinBoolean = false
        let settableRead = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        guard !spent() else { return outOfTime }
        var range: CFTypeRef?
        let rangeRead = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &range)
        guard !spent() else { return outOfTime }
        let role = stringAttribute(kAXRoleAttribute, of: focused)
        guard !spent() else { return outOfTime }
        let subrole = stringAttribute(kAXSubroleAttribute, of: focused)
        // An element whose role cannot be read is not "nothing focused": an empty role, not nil.
        let answer = FocusAnswer.classify(role: role ?? "", subrole: subrole,
                                          valueSettable: settableRead == .success && settable.boolValue,
                                          hasSelectedTextRange: rangeRead == .success, bundleID: app?.bundleIdentifier,
                                          ownWindowTextView: ownTextView)
        return Facts(answer: answer, role: role, subrole: subrole,
                     settable: settableRead == .success ? (settable.boolValue ? .yes : .no) : .error(settableRead.rawValue),
                     range: rangeRead == .success ? .yes : .error(rangeRead.rawValue),
                     selection: rangeRead == .success ? Self.cfRange(from: range) : nil)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Late AX exposure can turn what key-down saw into a field: nothing at all, or only a
    /// container, becomes the real text element once the app has built its accessibility tree.
    /// A late field is adopted only under `FocusRefresh.mayAdopt`, and is then bound for every guard.
    ///
    /// Every read made here for the look itself is bounded and asks `budget` first (`AXBounds`);
    /// one that fails, times out or is not started leaves the target as it was.
    @MainActor
    func refreshedForDelivery(budget: AXReadBudget = AXReadBudget()) -> FocusTarget {
        guard answer == .unknown, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == processID, app.bundleIdentifier == bundleID else { return self }
        return focusedElement == nil ? adoptingLateField(in: app, budget: budget)
            : adoptingFieldInsideContainer(in: app, budget: budget)
    }

    /// Key-down saw no element: a field focused now in the same window is adopted, when it
    /// positively reads as not a password field. (`verdict()` is the delivery guard's own check,
    /// on its usual timeout; the reads after it are this look's and are bounded.)
    @MainActor
    private func adoptingLateField(in app: NSRunningApplication, budget: AXReadBudget) -> FocusTarget {
        guard verdict() == .unchanged, let focusedWindow else { return self }
        let reader = AXFocusReader(asksSystem: true, budget: budget, systemGate: systemGate)
        guard let liveWindow = reader.focusedWindow(processID: app.processIdentifier),
              CFEqual(focusedWindow, liveWindow) else { return self }
        let query = reader.focusQuery(processID: app.processIdentifier)
        guard let live = query.element else { return self }
        let read = AXBounds.bounded(live) {
            (current: Self.facts(app: app, focused: live, budget: budget).answer,
             security: ContextReader.securityRead(of: live, isSpent: { budget.isSpent }).security)
        }
        guard FocusRefresh.mayAdopt(original: answer, hadElement: false, sameApp: true, sameWindow: true,
                                    current: read.current, security: read.security) else { return self }
        return adopting(live, viaSystem: query.source == .system)
    }

    /// Key-down saw a container (a web area, a group): a field focused now is adopted only when it
    /// sits inside that container, in the same window, and positively reads as not a password
    /// field. Anything else leaves the target as it was, and the guard treats the field as focus moved.
    ///
    /// A web area holds every field on its page, so "inside" is broad: see `FocusRefresh`.
    @MainActor
    private func adoptingFieldInsideContainer(in app: NSRunningApplication, budget: AXReadBudget) -> FocusTarget {
        // A key-down element that was itself a password field is never widened to its contents.
        guard !fieldIsSecure, let original = focusedElement, let focusedWindow else { return self }
        let reader = AXFocusReader(asksSystem: usesSystemQuery, budget: budget, systemGate: systemGate)
        guard let liveWindow = reader.focusedWindow(processID: app.processIdentifier),
              CFEqual(focusedWindow, liveWindow),
              let live = reader.focusedField(processID: app.processIdentifier), !CFEqual(live, original) else { return self }
        let read = AXBounds.bounded(live) {
            (current: Self.facts(app: app, focused: live, budget: budget).answer,
             security: ContextReader.securityRead(of: live, isSpent: { budget.isSpent }).security)
        }
        guard read.current == .field, read.security == .notSecure else { return self }
        let inside = FocusRefresh.isInside(
            live, ancestor: original,
            parent: { budget.isSpent ? nil : AXFocusReader.boundedParent(of: $0) }, isSame: { CFEqual($0, $1) })
        guard FocusRefresh.mayAdopt(original: answer, hadElement: true, sameApp: true, sameWindow: true,
                                    current: read.current, insideOriginal: inside, security: read.security) else { return self }
        return adopting(live, viaSystem: usesSystemQuery)
    }

    /// Only a field that read as not a password field is ever adopted (`FocusRefresh.mayAdopt`).
    private func adopting(_ live: AXUIElement, viaSystem: Bool) -> FocusTarget {
        var refreshed = self
        refreshed.answer = .field
        refreshed.focusedElement = live
        refreshed.hasStableFocusIdentity = true
        refreshed.fieldIsSecure = false
        refreshed.usesSystemQuery = viaSystem
        refreshed.adoptedLateField = true
        return refreshed
    }

    /// Counting a value means copying it out of the other app, up to six times per paste. Past
    /// this length the count is reported as unreadable instead.
    private static let longestCountedValue = 20_000

    /// One read of the field for the landing check, and how it ended (for the diagnosis line).
    /// Reads only numbers: a character count, a selection length and a caret position. The AX
    /// value is used only to count characters.
    ///
    /// `pin` holds the field the first read looked at. With nothing bound at key-down each read
    /// asks which field has focus, and a different field afterwards is not a read of the landing.
    /// The reads of the field are bounded and ask `budget` first (`AXBounds`); `verdict()` is the
    /// delivery guard's own check, on its usual timeout.
    ///
    /// `boundedGuard` bounds the guard check too (`verdict(budget:)`), for a read that runs after the paste and
    /// must never hold the main actor on a slow app.
    @MainActor
    func landingRead(pin: inout LandingPin<AXUIElement>, budget: AXReadBudget,
                     boundedGuard: Bool = false) -> (probe: LandingProbe?, status: PasteDiagnosis.Probe) {
        let live = boundedGuard ? verdict(budget: budget) : verdict()
        guard live == .unchanged, let processID else { return (nil, .targetMoved) }
        guard !budget.isSpent else { return (nil, .count(AXError.cannotComplete.rawValue)) }
        let reader = AXFocusReader(asksSystem: usesSystemQuery, budget: budget, systemGate: systemGate)
        guard let element = focusedElement ?? reader.focusedField(processID: processID) else { return (nil, .noElement) }
        guard pin.admits(element, isSame: { CFEqual($0, $1) }) else { return (nil, .otherElement) }
        return AXBounds.bounded(element) {
            let spent = { budget.isSpent }
            let security = ContextReader.securityRead(of: element, isSpent: spent)
            guard security.security == .notSecure else {
                return (nil, .security(security.security == .secure ? nil : security.error.rawValue))
            }
            let count = Self.characterCount(of: element, isSpent: spent)
            let selection = spent() ? nil : Self.selection(of: element)
            guard count.value != nil || selection != nil else { return (nil, count.status) }
            return (LandingProbe(characterCount: count.value, selectedLength: selection?.length,
                                 caretLocation: selection?.location), .ok)
        }
    }

    /// `readsValue` allows the fallback of counting the field's value when the count attribute is missing. The
    /// key-down read leaves it off: copying a long value out of another app is not worth a baseline.
    private static func characterCount(
        of element: AXUIElement, isSpent: () -> Bool, readsValue: Bool = true
    ) -> (value: Int?, status: PasteDiagnosis.Probe) {
        guard !isSpent() else { return (nil, .count(AXError.cannotComplete.rawValue)) }
        var countValue: CFTypeRef?
        let countRead = AXUIElementCopyAttributeValue(element, "AXNumberOfCharacters" as CFString, &countValue)
        if countRead == .success, let number = countValue as? NSNumber { return (number.intValue, .ok) }
        guard readsValue, countRead == .attributeUnsupported || countRead == .noValue else { return (nil, .count(countRead.rawValue)) }
        guard !isSpent() else { return (nil, .count(AXError.cannotComplete.rawValue)) }
        var value: CFTypeRef?
        let valueRead = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard valueRead == .success else { return (nil, .count(valueRead.rawValue)) }
        guard let string = value as? String else { return (nil, .valueType) }
        guard string.utf16.count <= longestCountedValue else { return (nil, .valueLong) }
        return (string.utf16.count, .ok)
    }

    private static func selection(of element: AXUIElement) -> CFRange? {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success else { return nil }
        return cfRange(from: selected)
    }

    private static func cfRange(from selected: CFTypeRef?) -> CFRange? {
        guard let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selected as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The key-down read of a known field: the selection the focus facts already returned, and one bounded read of
    /// the character count. Numbers only; nothing of the field's text is kept.
    @MainActor
    private static func keyDownProbe(of element: AXUIElement, selection: CFRange?) -> LandingProbe? {
        let budget = AXReadBudget()
        let count = AXBounds.bounded(element) { characterCount(of: element, isSpent: { budget.isSpent }, readsValue: false) }
        guard count.value != nil || selection != nil else { return nil }
        return LandingProbe(characterCount: count.value, selectedLength: selection?.length, caretLocation: selection?.location)
    }
}
