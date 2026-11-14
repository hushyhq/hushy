import Foundation

/// A named preset of how dictation is cleaned up and (optionally) transformed. Superwhisper
/// calls these "modes"; Hushy's version is the same idea: a name, an icon, a `CleanupLevel`,
/// an optional instruction ("make this a to-do list"), and an optional set of app bundle IDs
/// this mode should auto-select for.
///
/// A mode with no `prompt` is a plain cleanup-level preset (this is how the built-ins other
/// than Email/Message/Note/Bullet points would be expressed, and how a user's own "just clean
/// up, no email formatting" mode works). A mode with a `prompt` is a *transform* mode: its text
/// goes through `ModeExecutor`, which runs the on-device model with the prompt wrapped as data,
/// never as instructions the model executes on Hushy's behalf (see `ModeExecutor`).
public struct Mode: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// SF Symbol name shown in the mode chip/list/editor.
    public var icon: String
    public var cleanupLevel: CleanupLevel
    /// Instruction for the on-device model, e.g. "Format as a short professional email with a
    /// greeting and sign-off." `nil`/empty means this mode only sets the cleanup level.
    public var prompt: String?
    /// Bundle IDs this mode auto-selects for when Hushy detects that app is focused. Empty means
    /// manual-only (never auto-selected).
    public var appBundleIDs: [String]
    /// True for the five shipped modes; built-ins can be edited (a user tweaking "Email" is
    /// still useful) but never deleted, and duplicating one always produces a non-built-in copy.
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(), name: String, icon: String, cleanupLevel: CleanupLevel,
        prompt: String? = nil, appBundleIDs: [String] = [], isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.cleanupLevel = cleanupLevel
        self.prompt = prompt
        self.appBundleIDs = appBundleIDs
        self.isBuiltIn = isBuiltIn
    }

    /// Whether this mode's text should go through `ModeExecutor`'s transform path rather than
    /// just setting a cleanup level. A prompt of only whitespace behaves like no prompt at all.
    public var isTransform: Bool {
        guard let prompt else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fixed IDs so built-ins are stable across launches (settings JSON, eval goldens, and the
    /// "reset to defaults" affordance in the editor can all refer to a mode by ID).
    public enum BuiltInID {
        public static let `default` = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        public static let email = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        public static let message = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        public static let note = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        public static let bulletPoints = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    }

    /// The five shipped modes. `userName` fills the Email sign-off; pass the user's own name
    /// (from `AppSettings.userName`) so "Best, {name}" reads correctly without another model call.
    public static func builtIns(userName: String) -> [Mode] {
        let signOff = userName.trimmingCharacters(in: .whitespaces)
        let emailPrompt = signOff.isEmpty
            ? "Format as a concise email with a brief greeting and a sign-off."
            : "Format as a concise email with a brief greeting and a sign-off reading \"Best, \(signOff)\" (or a similarly short closing followed by \(signOff))."
        return [
            Mode(id: BuiltInID.default, name: "Default", icon: "waveform", cleanupLevel: .clean,
                 prompt: nil, appBundleIDs: [], isBuiltIn: true),
            Mode(id: BuiltInID.email, name: "Email", icon: "envelope", cleanupLevel: .clean,
                 prompt: emailPrompt, appBundleIDs: [], isBuiltIn: true),
            Mode(id: BuiltInID.message, name: "Message", icon: "message", cleanupLevel: .clean,
                 prompt: "Format as a short, casual message. Keep it brief.", appBundleIDs: [], isBuiltIn: true),
            Mode(id: BuiltInID.note, name: "Note", icon: "note.text", cleanupLevel: .clean,
                 prompt: "Format as a clear note. Keep sentences short.", appBundleIDs: [], isBuiltIn: true),
            Mode(id: BuiltInID.bulletPoints, name: "Bullet points", icon: "list.bullet", cleanupLevel: .clean,
                 prompt: "Reformat as a bulleted list, one point per line, each starting with \"- \".",
                 appBundleIDs: [], isBuiltIn: true),
        ]
    }
}

/// Resolves the stock Default preset against the user's Writing preference at key-down.
extension Mode {
    public var effectiveCleanupLevel: CleanupLevel { cleanupLevel }

    /// An unchanged Default cleanup preset inherits the app preference. A named/custom mode,
    /// transform prompt, or explicitly customized Default level remains an intentional override.
    /// The returned snapshot does not modify the user's stored preset or an in-flight session.
    public func resolvingAppCleanupLevel(_ appLevel: CleanupLevel) -> Mode {
        guard id == BuiltInID.default, isBuiltIn, cleanupLevel == .clean, !isTransform else { return self }
        var resolved = self
        resolved.cleanupLevel = appLevel
        return resolved
    }
}
