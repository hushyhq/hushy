import Foundation
import Testing

@testable import MurmurCore

/// An editor or a terminal is code: no tone is ever applied there, whatever the settings say.
@Suite("Code editors and terminals take no tone")
struct CodeAppToneTests {
    /// Identifiers as the apps ship them. The first group was already classified; the second was not
    /// until 2026-10-06 (task 112).
    private static let known = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.apple.dt.Xcode", "dev.zed.Zed", "com.apple.Terminal",
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.jetbrains.intellij",
        "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion",
    ]
    private static let added = [
        "com.sublimetext.2", "com.sublimetext.3", "com.sublimetext.4", "org.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.panic.Nova", "com.barebones.bbedit",
        "com.macromates.TextMate", "com.macromates.TextMate.preview", "com.google.android.studio", "com.vscodium",
        "org.gnu.Emacs", "org.vim.MacVim", "com.github.atom",
        "com.coteditor.CotEditor", "app.codeedit.CodeEdit", "org.tabby",
    ]

    @Test("every editor and terminal is classified as code")
    func classified() {
        for id in Self.known + Self.added {
            #expect(AppCategory.classify(bundleID: id) == .code, "\(id)")
        }
    }

    @Test("the tone plan for each is no tone, at the grammar-repair level, with every tone and with an app choice set")
    func noTone() {
        var settings = ToneSettings.standard
        for tone in ToneChoice.allCases {
            settings.choice = tone
            for id in Self.known + Self.added {
                let withChoice = settings.settingApp(.tone(.casual), bundleIDs: [id])
                let plan = withChoice.plan(for: AppCategory.classify(bundleID: id), bundleID: id)
                if settings.isAsSpoken {
                    #expect(plan.tone == nil && plan.level == .verbatim, "\(id)")
                } else {
                    #expect(plan.tone == nil && plan.level == .polished, "\(id)")
                }
            }
        }
    }

    @Test("ordinary writing apps are not turned into code")
    func notCode() {
        for id in ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.Notes", "net.whatsapp.WhatsApp",
                   "com.microsoft.Word", "us.zoom.xos", "com.apple.TextEdit"] {
            #expect(AppCategory.classify(bundleID: id) != .code, "\(id)")
        }
    }
}
