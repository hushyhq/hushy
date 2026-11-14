import Foundation
import Testing
@testable import MurmurCore

/// TRY-84: a prompt dictated into Cursor's agent box came out raw, because Cursor is classified as code. The focused field now
/// decides: a chat or agent box is an AI prompt (prose cleanup, Prompt register), the code buffer and the terminal stay code.
/// Only the class names and labels of the focused field are read; the app side is `EditorChatReader`.
@Suite("Code editors: chat box or code", .timeLimit(.minutes(1)))
struct EditorChatSurfaceTests {
    private let cursor = "com.todesktop.230313mzl4w4u92"
    private let windsurf = "com.exafunction.windsurf"
    private let vsCode = "com.microsoft.VSCode"
    private let terminal = "com.apple.Terminal"

    // Shapes as the editors build them (class tokens read from the shipped Cursor 3.27 and VS Code 1.143 bundles).
    private let cursorAgentBox = EditorChatSurface.Facts(classNames: ["aislash-editor-input", "full-input-box"], labels: [])
    private let vsCodeChatInput = EditorChatSurface.Facts(
        classNames: ["inputarea", "monaco-editor", "chat-editor-container", "chat-input-container", "interactive-input-part"],
        labels: ["Chat Input"])
    private let monacoBuffer = EditorChatSurface.Facts(
        classNames: ["inputarea", "monaco-mouse-cursor-text", "monaco-editor", "no-user-select", "vs-dark"],
        labels: ["Editor content"])
    private let integratedTerminal = EditorChatSurface.Facts(
        classNames: ["xterm-helper-textarea", "xterm"], labels: ["Terminal 1, zsh"])

    private func settings(_ id: String, prompt: Bool) -> PipelineSettings {
        let category = prompt ? AppCategory.aiPrompts : AppCategory.classify(bundleID: id, windowTitle: nil)
        let tones = ToneSettings.standard
        let mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        return PipelineSettings.forDictation(
            cleanup: CleanupOptions(level: tones.dictationLevel), tone: tones, mode: mode,
            category: category, bundleID: id, windowTitle: nil)
    }

    // MARK: Which field

    @Test("Cursor's agent box and VS Code's chat input read as chat; the chat marker beats the Monaco editor it is built on")
    func chatBoxes() {
        #expect(EditorChatSurface.surface(for: cursorAgentBox) == .chat)
        #expect(EditorChatSurface.surface(for: vsCodeChatInput) == .chat)
        #expect(EditorChatSurface.isPrompt(bundleID: cursor, facts: cursorAgentBox))
        #expect(EditorChatSurface.isPrompt(bundleID: vsCode, facts: vsCodeChatInput))
        #expect(EditorChatSurface.isPrompt(bundleID: windsurf, facts: vsCodeChatInput))
    }

    @Test("the code buffer and the integrated terminal stay code in every editor, including the AI editors")
    func codeFields() {
        for facts in [monacoBuffer, integratedTerminal] {
            #expect(EditorChatSurface.surface(for: facts) == .code)
            for id in [cursor, windsurf, vsCode] { #expect(!EditorChatSurface.isPrompt(bundleID: id, facts: facts), "\(id)") }
        }
        // A label alone is enough when the class names are not exposed.
        #expect(EditorChatSurface.surface(for: .init(labels: ["Terminal 2"])) == .code)
        #expect(EditorChatSurface.surface(for: .init(labels: ["Editor content;Press Alt+F1 for Accessibility Options."])) == .code)
    }

    @Test("a field that cannot be placed is a prompt in Cursor and Windsurf (AI editors) and code in VS Code")
    func unplacedField() {
        for facts in [EditorChatSurface.Facts(), .init(classNames: ["some-new-class"], labels: ["Sidebar"])] {
            #expect(EditorChatSurface.surface(for: facts) == .unknown)
            #expect(EditorChatSurface.isPrompt(bundleID: cursor, facts: facts))
            #expect(EditorChatSurface.isPrompt(bundleID: windsurf, facts: facts))
            #expect(!EditorChatSurface.isPrompt(bundleID: vsCode, facts: facts))
        }
    }

    @Test("a read-only transcript is not the input; other apps are never changed by this")
    func readOnlyAndOtherApps() {
        #expect(EditorChatSurface.surface(for: .init(classNames: ["aislash-editor-input-readonly"])) == .unknown)
        for id in [terminal, "com.apple.dt.Xcode", "com.anthropic.claudefordesktop", "com.apple.Notes"] {
            #expect(!EditorChatSurface.isPrompt(bundleID: id, facts: cursorAgentBox), "\(id)")
            #expect(!EditorChatSurface.isPrompt(bundleID: id, surface: .unknown), "\(id)")
        }
        #expect(!EditorChatSurface.isPrompt(bundleID: nil, surface: .chat))
    }

    @Test("the editors stay classified as code; Windsurf is checked for a terminal agent like Cursor and VS Code")
    func classificationUnchanged() {
        for id in [cursor, windsurf, vsCode] {
            #expect(AppCategory.classify(bundleID: id) == .code, "\(id)")
            #expect(TerminalAgentContext.isCandidate(bundleID: id), "\(id)")
        }
    }

    // MARK: What the dictation gets

    @Test("a prompt in Cursor's agent box is cleaned like one in Claude: prose, a tone, the Prompt register; the buffer is unchanged")
    func planForChatAndBuffer() {
        let chat = settings(cursor, prompt: true)
        #expect(!chat.cleanupOptions.isCodeContext)
        #expect(chat.cleanupOptions.level == .polished)
        #expect(chat.style != nil && chat.tone != nil)
        #expect(chat.cleanupOptions.register == .prompt)
        let claude = settings("com.anthropic.claudefordesktop", prompt: false)
        #expect(chat.cleanupOptions.register == claude.cleanupOptions.register)
        #expect(chat.tone == claude.tone && chat.cleanupOptions.level == claude.cleanupOptions.level)

        let buffer = settings(cursor, prompt: false)
        #expect(buffer.cleanupOptions.isCodeContext)
        #expect(buffer.style == nil && buffer.tone == nil)
        #expect(buffer.cleanupOptions.register == nil)
    }

    @Test("the rules take the fillers and the stutter out of a prompt in the agent box; the buffer keeps the words as spoken")
    func rulesInChatAndBuffer() {
        let spoken = "okay so um can you add tests for the the parser and then fix the failing one"
        let chat = TextCleaner(options: settings(cursor, prompt: true).cleanupOptions).clean(spoken).text
        let buffer = TextCleaner(options: settings(cursor, prompt: false).cleanupOptions).clean(spoken).text
        #expect(!chat.lowercased().contains(" um ") && !chat.contains("the the"), "\(chat)")
        #expect(buffer.contains("the the") || buffer.lowercased().contains(" um "), "\(buffer)")
    }

    @Test("the rules treat what is said in the agent box exactly as in Claude: as words, no spoken code written")
    func sameRulesAsClaude() {
        let agentBox = settings(cursor, prompt: true).cleanupOptions
        let claude = settings("com.anthropic.claudefordesktop", prompt: false).cleanupOptions
        for spoken in [
            "please run swift test dash dash parallel and tell me which ones fail", "can you open auth dot swift and check the retry",
            "update the readme so new people can set it up and then merge the prs", "git push origin main",
        ] {
            #expect(TextCleaner(options: agentBox).clean(spoken).text == TextCleaner(options: claude).clean(spoken).text, "\(spoken)")
        }
    }
}
