import Foundation

/// Tells an AI chat or agent box inside a code editor (Cursor's agent box, VS Code's chat view, Windsurf's chat) from the
/// editor buffer and the integrated terminal that sit in the same window (TRY-84).
///
/// Cursor, Windsurf and VS Code are classified as code (`AppCategory.classify`), which is right for the buffer and wrong for
/// the box where someone dictates a prompt: a code context keeps the words as spoken, so a prompt came out raw. The focused
/// field decides, not the app (AGENTS.md: people dictate prompts, not code, in agent surfaces). The editors are Chromium
/// apps, so the focused element and its ancestors can say what they are through the DOM class names Chromium exposes to
/// Accessibility (`AXDOMClassList`) and their labels. This type is pure: the app reads the facts (`EditorChatReader`), and
/// this decides.
///
/// - A chat box is recognised by its own markers (Cursor's `aislash-editor-input`, VS Code's `interactive-input-part` and
///   `chat-input-container`). They win over everything, because VS Code's chat input is itself a Monaco editor.
/// - The code buffer (`monaco-editor`) and the terminal (`xterm`, or a "terminal" label) stay code.
/// - When the field says neither: Cursor and Windsurf are AI editors and are treated as prompts (prose cleanup, with the
///   protection of unambiguous spoken tokens); VS Code stays code, as it was.
public enum EditorChatSurface {
    /// What the focused field is.
    public enum Surface: String, Sendable, Equatable {
        case chat, code, unknown
    }

    /// What was read from the focused element and its ancestors. Class tokens and labels only; never field text.
    public struct Facts: Sendable, Equatable {
        public var classNames: [String]
        public var labels: [String]

        public init(classNames: [String] = [], labels: [String] = []) {
            self.classNames = classNames
            self.labels = labels
        }

        public var isEmpty: Bool { classNames.isEmpty && labels.isEmpty }
    }

    /// Cursor, Windsurf and VS Code: the editors with a chat box inside.
    private static let editors: Set<String> = [
        "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]
    /// Editors that are an AI product first: a field that cannot be placed is a prompt there.
    private static let aiFirst: Set<String> = ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

    private static let chatClasses: Set<String> = [
        "aislash-editor-input", "full-input-box",
        "interactive-input-part", "chat-input-container", "chat-editor-container",
    ]
    private static let codeClasses: Set<String> = ["monaco-editor", "xterm", "xterm-helper-textarea", "terminal-wrapper"]
    private static let chatLabels = ["chat input"]
    private static let codeLabels = ["terminal", "editor content"]

    public static func isEditor(bundleID: String?) -> Bool {
        bundleID.map { editors.contains($0.lowercased()) } ?? false
    }

    /// Cursor and Windsurf: AI editors, where an unplaced field is treated as a prompt.
    public static func isAIFirst(bundleID: String?) -> Bool {
        bundleID.map { aiFirst.contains($0.lowercased()) } ?? false
    }

    /// What the focused field is, from the class names and labels along its chain. A chat marker wins over a code one.
    public static func surface(for facts: Facts) -> Surface {
        let classes = Set(facts.classNames.map { $0.lowercased() })
        let labels = facts.labels.map { $0.lowercased() }
        if !classes.isDisjoint(with: chatClasses) || labels.contains(where: { label in chatLabels.contains { label.contains($0) } }) {
            return .chat
        }
        if !classes.isDisjoint(with: codeClasses) || labels.contains(where: { label in codeLabels.contains { label.contains($0) } }) {
            return .code
        }
        return .unknown
    }

    /// True when a dictation in this editor is a prompt: a chat box, or a field that cannot be placed in an AI editor.
    public static func isPrompt(bundleID: String?, surface: Surface) -> Bool {
        guard isEditor(bundleID: bundleID) else { return false }
        switch surface {
        case .chat: return true
        case .code: return false
        case .unknown: return isAIFirst(bundleID: bundleID)
        }
    }

    public static func isPrompt(bundleID: String?, facts: Facts) -> Bool {
        isPrompt(bundleID: bundleID, surface: surface(for: facts))
    }
}
