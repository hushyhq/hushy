import AppKit
import ApplicationServices
import MurmurCore

/// Slow process and Accessibility lookups run only in `startWindowRead`'s detached task.
enum TerminalAgentReader {
    /// `agent` is true for a prompt box: a terminal agent session, or the chat or agent box of a code editor
    /// (`EditorChatSurface`). `surface` is what the editor's focused field was read as, nil for any other app.
    static func inspect(bundleID: String?, pid: pid_t, excludedApps: Set<String>, readsScreen: Bool)
        -> (agent: Bool, surface: EditorChatSurface.Surface?, outcome: WindowContextReader.Outcome?, milliseconds: Int) {
        let started = ContinuousClock.now
        let surface = EditorChatReader.surface(bundleID: bundleID, pid: pid)
        let terminalAgent = isAgent(bundleID: bundleID, pid: pid)
        let agent = terminalAgent || surface.map { EditorChatSurface.isPrompt(bundleID: bundleID, surface: $0) } == true
        let spent = ContinuousClock.now - started
        let milliseconds = Int(spent.components.seconds * 1_000
            + spent.components.attoseconds / 1_000_000_000_000_000)
        let outcome = readsScreen ? WindowContextReader.read(
            bundleID: bundleID, pid: pid, excludedApps: excludedApps, terminal: terminalAgent) : nil
        return (agent, surface, outcome, milliseconds)
    }

    static func isAgent(bundleID: String?, pid: pid_t) -> Bool {
        guard TerminalAgentContext.isCandidate(bundleID: bundleID) else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var focusedWindow: CFTypeRef?
        var title: String?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow, CFGetTypeID(window) == AXUIElementGetTypeID() {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &raw) == .success {
                title = raw as? String
            }
        }
        var focused: CFTypeRef?
        var description: String?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var current = focused as! AXUIElement
            for _ in 0..<4 {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, kAXDescriptionAttribute as CFString, &raw) == .success,
                   let value = raw as? String, value.localizedCaseInsensitiveContains("terminal") {
                    description = value; break
                }
                if AXUIElementCopyAttributeValue(current, kAXTitleAttribute as CFString, &raw) == .success,
                   let value = raw as? String, value.localizedCaseInsensitiveContains("terminal") {
                    description = value; break
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = parent as! AXUIElement
            }
        }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,pgid=,tpgid=,tty=,comm="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        let jobs: [TerminalAgentContext.Job]
        if (try? ps.run()) != nil {
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            jobs = TerminalAgentContext.parsePS(String(decoding: bytes, as: UTF8.self))
        } else { jobs = [] }
        return TerminalAgentContext.isAgent(bundleID: bundleID, terminalPID: pid, title: title,
                                            focusedDescription: description, jobs: jobs)
    }
}
