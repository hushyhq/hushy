import AppKit
import ApplicationServices
import Foundation
import MurmurCore

// hushy-ax-probe <pid> [--budget-ms 150] [--no-manual] [--enhanced]
//
// Measures how much text of one app's focused window is reachable through the Accessibility API (docs/product/
// SCREEN-CONTEXT-PLAN.md, "Accessibility reach"). It walks the tree for up to 150 ms and prints counts: elements visited,
// text elements, total characters, time, and whether setting AXManualAccessibility on the app element changed them.
// It never prints, logs or saves any text it reads: a node reports only how many characters it holds.
//
// Run by the person who owns the app, on their own Mac, from a terminal that has the Accessibility permission. Setting
// AXManualAccessibility asks the app to build its tree (Electron and Chromium apps leave it off); the probe puts the
// attribute back the way it found it. Skip that step with --no-manual.

private let passwordManagers: Set<String> = [
    "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7",
    "com.bitwarden.desktop", "com.lastpass.lastpassmacdesktop", "com.dashlane.dashlanephonefinal",
    "com.callpod.keepersecurity", "com.nordpass.macos", "com.apple.Passwords",
    "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.preference.security",
]
/// Roles whose title or description counts as text on screen (value counts for every role).
private let titledRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell"]

private struct AXNode: AccessibilityReachNode {
    let element: AXUIElement

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    var isWebArea: Bool { string(kAXRoleAttribute) == "AXWebArea" }

    func textCharacterCount() -> Int {
        let role = string(kAXRoleAttribute)
        // A secure field's value is never read.
        if role == "AXSecureTextField" || (string(kAXSubroleAttribute) ?? "").localizedCaseInsensitiveContains("secure") { return 0 }
        var longest = string(kAXValueAttribute)?.count ?? 0
        if let role, titledRoles.contains(role) {
            longest = max(longest, string(kAXTitleAttribute)?.count ?? 0, string(kAXDescriptionAttribute)?.count ?? 0)
        }
        return longest
    }

    func childNodes() -> [any AccessibilityReachNode] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.map { AXNode(element: $0) }
    }
}

private func role(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}

/// The window to walk: the focused window, else the main window, else the first window the app lists. Only an element
/// whose role is AXWindow (or AXSheet, AXDialog) counts: an app that is not frontmost can answer the focused-window
/// question with its application element, and walking that reads the menu bar instead of the window.
private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    let windowRoles: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXFloatingWindow"]
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
           let name = role(of: value as! AXUIElement), windowRoles.contains(name) { return (value as! AXUIElement) }
    }
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
       let list = windows as? [AXUIElement] {
        return list.first { role(of: $0).map(windowRoles.contains) ?? false }
    }
    return nil
}

private func measure(_ app: AXUIElement, budget: AccessibilityReachProbe.Budget) -> AccessibilityReachCounts? {
    guard let window = focusedWindow(of: app) else { return nil }
    let started = ContinuousClock.now
    return AccessibilityReachProbe.walk(root: AXNode(element: window), budget: budget) {
        let spent = ContinuousClock.now - started
        return Int(spent.components.seconds * 1_000 + spent.components.attoseconds / 1_000_000_000_000_000)
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let target = arguments.first, !target.hasPrefix("--") else {
    fail("usage: hushy-ax-probe <app name or pid> [--budget-ms 150] [--no-manual] [--enhanced] [--roles]   (for example: hushy-ax-probe Claude)")
}
/// A pid, or the name of a running app as the Dock shows it ("Claude", "Slack", "Mail").
let pid: pid_t = pid_t(target) ?? {
    let matches = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame
    }
    guard let app = matches.first else { fail("\(target) is not running. Open it with a conversation showing, then run this again.") }
    return app.processIdentifier
}()
let budgetMs = arguments.firstIndex(of: "--budget-ms").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 150
let tryManual = !arguments.contains("--no-manual")
guard AXIsProcessTrusted() else { fail("This terminal does not have the Accessibility permission (System Settings > Privacy & Security).") }
guard let running = NSRunningApplication(processIdentifier: pid) else { fail("No running app has pid \(pid).") }
if let bundle = running.bundleIdentifier, passwordManagers.contains(bundle) { fail("Refusing to read this app (password manager or credential surface).") }

let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 0.05)
let budget = AccessibilityReachProbe.Budget(milliseconds: budgetMs)
// Chromium and WebKit build their accessibility tree only after the first assistive client asks, so the first answer
// can be "no window" or a stub. Ask again for a few seconds before giving up; each try is counted.
var attempts = 0
var firstTry: AccessibilityReachCounts?
while firstTry == nil, attempts < 8 {
    attempts += 1
    firstTry = measure(appElement, budget: budget)
    if firstTry == nil { Thread.sleep(forTimeInterval: 0.5) }
}
if firstTry == nil {
    // Say why, in error codes: -25204 cannot complete, -25205 attribute unsupported, -25211 API disabled, -25212 no value.
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXWindowsAttribute, kAXChildrenAttribute] {
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
        var detail = ""
        if code == .success, let list = value as? [AXUIElement] { detail = ", \(list.count) items, roles: " + list.prefix(6).map { role(of: $0) ?? "?" }.joined(separator: " ") }
        else if code == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() { detail = ", one element, role \(role(of: value as! AXUIElement) ?? "?")" }
        print("\(attribute): code \(code.rawValue)\(detail)")
    }
}
guard let before = firstTry else { fail("The app has no window the probe can reach (\(attempts) tries over \(Double(attempts) * 0.5) s).") }
if attempts > 1 { print("window found on try \(attempts)") }
print(AccessibilityReachProbe.line("default", before))

/// Sets a boolean attribute on the app element, measures after `settle` seconds, and puts it back the way it was.
/// Returns false when the app does not accept the attribute.
@discardableResult
private func trying(_ appElement: AXUIElement, _ before: AccessibilityReachCounts, _ budget: AccessibilityReachProbe.Budget,
                    _ attribute: String, label: String, settle: [Double]) -> Bool {
    var previous: CFTypeRef?
    let hadValue = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &previous) == .success
    let wasOn = (previous as? Bool) ?? false
    let set = AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanTrue)
    guard set == .success else {
        print("\(label): could not be set (\(set.rawValue)); the app does not accept it")
        return false
    }
    var waited = 0.0
    for point in settle {
        // Web engines build their tree on the next run loop turns after an assistive client announces itself.
        Thread.sleep(forTimeInterval: point - waited)
        waited = point
        if let after = measure(appElement, budget: budget) {
            print(AccessibilityReachProbe.line("\(label) after \(point) s", after))
            print("\(label) after \(point) s changed the counts: elements \(after.elementsVisited - before.elementsVisited), "
                  + "characters \(after.totalCharacters - before.totalCharacters), web characters \(after.webCharacters - before.webCharacters)")
        }
    }
    if !wasOn || !hadValue { _ = AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanFalse) }
    return true
}

if tryManual { trying(appElement, before, budget, "AXManualAccessibility", label: "AXManualAccessibility", settle: [0.5]) }
// AXEnhancedUserInterface is what Chromium and WebKit browsers watch for. It is a side effect on the app, not just a
// read: AppKit apps turn off window animations and some window managers misbehave while it is on. The probe sets it
// only when asked (--enhanced), waits, measures, and puts it back; the app itself must not use it.
if arguments.contains("--enhanced") { trying(appElement, before, budget, "AXEnhancedUserInterface", label: "AXEnhancedUserInterface", settle: [0.5, 2.0]) }

// --roles: a count of the elements by role and by depth, to see where the page content sits (or why the walk never
// reaches it). Roles and counts only; no text, titles or values are read.
if arguments.contains("--roles"), let window = focusedWindow(of: appElement) {
    var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
    var head = 0
    var rootRole: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &rootRole)
    print("roles: the walk starts at a \(rootRole as? String ?? "?"); app is frontmost: \(running.isActive)")
    var byRole: [String: Int] = [:]
    var firstWebAreaDepth: Int?
    var seen = Set<AnyHashable>()
    var repeats = 0
    var deepest = 0
    let started = ContinuousClock.now
    while head < queue.count, ContinuousClock.now - started < .milliseconds(budgetMs) {
        let (element, depth) = queue[head]
        head += 1
        if !seen.insert(AnyHashable(element)).inserted { repeats += 1; continue }
        deepest = max(deepest, depth)
        var role: CFTypeRef?
        let name = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success ? (role as? String ?? "?") : "unreadable"
        byRole[name, default: 0] += 1
        if name == "AXWebArea", firstWebAreaDepth == nil { firstWebAreaDepth = depth }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
            queue.append(contentsOf: list.map { ($0, depth + 1) })
        }
    }
    print("roles: visited=\(seen.count) repeated=\(repeats) deepest=\(deepest) firstWebAreaDepth=\(firstWebAreaDepth.map(String.init) ?? "none") queued=\(queue.count)")
    print("roles: " + byRole.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
}
