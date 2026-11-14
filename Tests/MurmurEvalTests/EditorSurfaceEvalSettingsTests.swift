import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Editor surface in the eval settings")
struct EditorSurfaceEvalSettingsTests {
    private let cursor = "com.todesktop.230313mzl4w4u92"

    @Test("a chat box in Cursor runs as an AI prompt with the Prompt register; the buffer and a case with no surface run as code")
    func surfaceChangesTheCategory() {
        let chat = LiveShapeRunner.settings(tone: .refined, bundleID: cursor, surface: .chat)
        #expect(chat.1 == .aiPrompts && !chat.0.cleanupOptions.isCodeContext && chat.0.cleanupOptions.register == .prompt)
        for surface in [EditorChatSurface.Surface.code, nil] {
            let code = LiveShapeRunner.settings(tone: .refined, bundleID: cursor, surface: surface)
            #expect(code.1 == .code && code.0.cleanupOptions.isCodeContext && code.0.cleanupOptions.register == nil)
        }
        // An unplaced field in Cursor is a prompt; the same field in VS Code is code.
        #expect(LiveShapeRunner.settings(tone: .refined, bundleID: cursor, surface: .unknown).1 == .aiPrompts)
        #expect(LiveShapeRunner.settings(tone: .refined, bundleID: "com.microsoft.VSCode", surface: .unknown).1 == .code)
    }
}
