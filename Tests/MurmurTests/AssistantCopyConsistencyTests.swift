import Foundation
import Testing

/// The Assistant reads meeting notes only, never dictations (`.claude/DECISIONS.md`, "The
/// Assistant reads meeting notes only, never dictations"). Past copy drift claimed otherwise —
/// the empty-state subtitle said "searches your dictations and notes" while the composer
/// placeholder said "meeting notes", and Settings' description repeated the same "dictations
/// and notes" claim. Product direction (2026-09-27) asks for the opposite: every Assistant
/// string should say plainly that dictations are *not* shared, and "dictations" should appear
/// nowhere else in that UI (no stray implication that they're in scope).
///
/// This greps the actual source files rather than re-typing their strings, so it fails the
/// moment new Assistant-facing copy reintroduces the word outside the one sanctioned statement.
@Suite("Assistant copy consistency")
struct AssistantCopyConsistencyTests {
    /// Files that make up the Assistant's user-facing copy surface (chat view, opt-in/consent
    /// cards, and its Settings row) — the same surface the task's copy-inconsistency feedback
    /// was about.
    private static let assistantCopyFiles = [
        "Sources/Murmur/UI/Screens/Assistant/AssistantChatView.swift",
        "Sources/Murmur/UI/Screens/Assistant/AssistantOptInViews.swift",
        "Sources/Murmur/UI/Screens/Assistant/AssistantColumn.swift",
        "Sources/Murmur/UI/Screens/Settings/AssistantSettingsSection.swift",
    ]

    /// Every line mentioning "dictation" must be the sanctioned "never shared" statement (or a
    /// code comment describing it) — never a claim that dictations are searched or included.
    private static let forbiddenPhrases = [
        "dictations and notes",
        "your dictations",
        "searches your dictations",
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AssistantCopyConsistencyTests.swift
            .deletingLastPathComponent() // MurmurTests
            .deletingLastPathComponent() // Tests
    }

    @Test("dictations only appears in the explicit never-shared statement")
    func dictationsOnlyInNeverSharedStatement() throws {
        let root = repoRoot()
        var mentionLines: [String] = []
        for relativePath in Self.assistantCopyFiles {
            let url = root.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.localizedCaseInsensitiveContains("dictation") else { continue }
                mentionLines.append(String(line))
            }
        }

        #expect(!mentionLines.isEmpty, "expected at least the sanctioned never-shared statement")

        for line in mentionLines {
            let saysNeverShared = line.localizedCaseInsensitiveContains("never shared")
            #expect(saysNeverShared, "unexpected dictation mention outside the never-shared statement: \(line)")
        }

        for forbidden in Self.forbiddenPhrases {
            for relativePath in Self.assistantCopyFiles {
                let url = root.appendingPathComponent(relativePath)
                let contents = try String(contentsOf: url, encoding: .utf8)
                #expect(!contents.localizedCaseInsensitiveContains(forbidden), "'\(forbidden)' found in \(relativePath)")
            }
        }
    }

    @Test("the suggested prompts no longer include the reminder action")
    func noReminderSuggestion() throws {
        let url = repoRoot().appendingPathComponent("Sources/Murmur/Assistant/AssistantModel.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("Remind me tomorrow at 9 to send the deck"))
    }

    @Test("the composer placeholder and empty state both say meetings, not meeting notes only")
    func placeholderMatchesDirection() throws {
        let url = repoRoot().appendingPathComponent("Sources/Murmur/UI/Screens/Assistant/AssistantChatView.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("\"Ask about your meetings…\""))
        #expect(contents.contains("\"Ask about your meetings\""))
    }
}
