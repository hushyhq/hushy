import Foundation

/// A snapshot from `ps`; process enumeration is done while the person speaks, never at key-down.
public enum TerminalAgentContext {
    public struct Job: Sendable, Equatable {
        public let pid: Int32
        public let parent: Int32
        public let group: Int32
        public let foregroundGroup: Int32
        public let tty: String
        public let command: String

        public init(pid: Int32, parent: Int32, group: Int32, foregroundGroup: Int32,
                    tty: String, command: String) {
            self.pid = pid; self.parent = parent; self.group = group
            self.foregroundGroup = foregroundGroup; self.tty = tty; self.command = command
        }
    }

    private static let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "ghostty", "warp",
                                    "org.alacritty", "wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper", "org.tabby"]
    private static let editors = ["com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]
    private static let agents: Set<String> = ["claude", "codex", "cursor-agent", "agent", "gemini", "aider"]
    private static let nonAgents: Set<String> = ["zsh", "bash", "fish", "sh", "vim", "nvim", "emacs"]

    public static func isCandidate(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return terminals.contains { id.contains($0) } || editors.contains(id)
    }

    public static func isAgent(bundleID: String?, terminalPID: Int32, title: String?,
                               focusedDescription: String?, jobs: [Job]) -> Bool {
        guard let id = bundleID?.lowercased(), isCandidate(bundleID: id) else { return false }
        let integrated = editors.contains(id)
        // An editor may have several unrelated terminals open. Require the focused AX branch to say Terminal.
        if integrated && !(focusedDescription ?? "").localizedCaseInsensitiveContains("terminal") { return false }
        let titleCommands: [String] = (title ?? "").lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "—–|:·"))
            .compactMap { part in
                let words = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                guard let first = words.first, !first.contains("/"),
                      words.count == 1 || words.dropFirst().allSatisfy({ $0.first == "-" })
                else { return nil }
                return URL(fileURLWithPath: String(first)).lastPathComponent
            }
        if titleCommands.contains(where: nonAgents.contains) && !titleCommands.contains(where: agents.contains) {
            return false
        }
        let byPID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.pid, $0) })
        let foreground = jobs.filter { job in
            guard job.tty != "??", job.group > 0, job.group == job.foregroundGroup,
                  agents.contains(URL(fileURLWithPath: job.command).lastPathComponent.lowercased()) else { return false }
            var parent = job.parent
            var seen = Set<Int32>()
            while parent > 0, seen.insert(parent).inserted {
                if parent == terminalPID { return true }
                parent = byPID[parent]?.parent ?? 0
            }
            return false
        }
        if !foreground.isEmpty { return true }
        // Terminal titles commonly contain the command between separators. Reject filenames and prose mentions.
        return !integrated && titleCommands.contains(where: agents.contains)
    }

    public static func parsePS(_ output: String) -> [Job] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            guard fields.count == 6, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let group = Int32(fields[2]), let foreground = Int32(fields[3]) else { return nil }
            return Job(pid: pid, parent: parent, group: group, foregroundGroup: foreground,
                       tty: String(fields[4]), command: String(fields[5]))
        }
    }
}
