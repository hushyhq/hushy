import Foundation
import Testing
@testable import Murmur

/// Updates that install themselves: the notes behind "What's new", the one prompt that asks
/// about relaunching, and the build defaults that make the whole thing happen.
@MainActor
@Suite("Update flow")
struct UpdateFlowTests {
    // MARK: Release notes

    @Test("embedded plain text and Markdown notes are shown as written")
    func plainNotes() {
        let notes = "- Faster start\n- Fewer pauses"
        #expect(UpdateReleaseNotes.make(description: notes, format: "plain-text", link: nil) == .text(notes))
        #expect(UpdateReleaseNotes.make(description: "  \(notes)\n", format: "markdown", link: nil) == .text(notes))
    }

    @Test("embedded HTML notes become readable lines")
    func htmlNotes() {
        let html = "<h2>1.4</h2><ul><li>Faster &amp; calmer</li><li>Fixes a <b>paste</b> bug</li></ul>"
        #expect(UpdateReleaseNotes.make(description: html, format: "html", link: nil)
            == .text("1.4\n• Faster & calmer\n• Fixes a paste bug"))
        #expect(UpdateReleaseNotes.make(description: "<p>One</p><p>Two</p>", format: nil, link: nil) == .text("One\nTwo"))
    }

    @Test("with no embedded notes the link is used, and with neither there is nothing to show")
    func linkOrNothing() throws {
        let page = try #require(URL(string: "https://updates.tryhushy.com/notes/1.4"))
        #expect(UpdateReleaseNotes.make(description: nil, format: nil, link: page) == .link(page))
        #expect(UpdateReleaseNotes.make(description: "  ", format: "html", link: page) == .link(page))
        #expect(UpdateReleaseNotes.make(description: "<br>", format: "html", link: page) == .link(page))
        #expect(UpdateReleaseNotes.make(description: nil, format: nil, link: nil) == .none)
    }

    @Test("only an https page on tryhushy.com or a subdomain is offered as a link")
    func trustedLinks() throws {
        func notes(_ raw: String) throws -> UpdateReleaseNotes {
            UpdateReleaseNotes.make(description: nil, format: nil, link: try #require(URL(string: raw)))
        }
        for good in ["https://tryhushy.com/notes", "https://updates.tryhushy.com/notes/1.4", "https://TryHushy.com/x"] {
            #expect(try notes(good) == .link(try #require(URL(string: good))), "\(good)")
        }
        for bad in ["http://tryhushy.com/notes", "https://evil.example/notes", "https://tryhushy.com.evil.example/n",
                    "https://nottryhushy.com/n", "file:///etc/passwd", "javascript:alert(1)", "https://user:pw@tryhushy.com/n",
                    "hushy://notes"] {
            #expect(try notes(bad) == .none, "\(bad)")
        }
    }

    @Test("an untrusted notes link does not replace embedded notes, and embedded notes still win")
    func untrustedLinkWithEmbeddedNotes() throws {
        let evil = try #require(URL(string: "https://evil.example/n"))
        #expect(UpdateReleaseNotes.make(description: "Faster", format: "plain-text", link: evil) == .text("Faster"))
    }

    @Test("a Markdown link in the notes shows as plain text and is not clickable")
    func notesAreNotClickable() {
        let text = UpdateReleaseNotes.attributed("- See [the details](https://evil.example/x) and https://evil.example/y\n- <https://evil.example/z>")
        #expect(String(text.characters).contains("the details"))
        #expect(!String(text.characters).contains("]("), "the Markdown link is rendered, not shown raw")
        #expect(text.runs.allSatisfy { $0.link == nil })
        #expect(String(text.characters).hasPrefix("• "))
    }

    // MARK: Words

    @Test("the prompt offers relaunch now or later, and shows no version number")
    func promptCopy() {
        #expect(UpdateCopy.readyTitle == "A new version of Hushy is ready")
        let hasDigit = UpdateCopy.readyTitle.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        #expect(!hasDigit, "the marketing version never changes; build numbers are not shown")
        #expect(UpdateCopy.relaunchNow == "Relaunch now")
        #expect(UpdateCopy.later == "Later")
        #expect(UpdateCopy.readyDetail.contains("installs when you quit"), "Later must say what happens")
    }

    @Test("Settings says what the switch does in each state")
    func statusCopy() {
        #expect(UpdateCopy.statusText(installsAutomatically: true).contains("background"))
        #expect(UpdateCopy.statusText(installsAutomatically: false).contains("asks before installing"))
        #expect(UpdateCopy.statusText(installsAutomatically: true, checksAutomatically: false) == "Checks only when you ask.")
    }

    @Test("an unconfigured build has no automatic installs to switch on")
    func unconfiguredSwitch() {
        let checker = UnconfiguredUpdateChecker()
        checker.installsAutomatically = true
        #expect(!checker.installsAutomatically)
    }

    // MARK: The relaunch prompt

    private final class RecordingPresenter: UpdateReadyPresenting {
        var shown: [(prompt: UpdateReadyPrompt, relaunch: () -> Void, later: () -> Void)] = []
        var dismissals = 0
        func present(_ prompt: UpdateReadyPrompt, relaunch: @escaping () -> Void, later: @escaping () -> Void) {
            shown.append((prompt, relaunch, later))
        }
        func dismiss() { dismissals += 1 }
    }

    private let prompt = UpdateReadyPrompt(notes: .text("Faster"))

    @Test("a downloaded update is announced once, and Relaunch now installs it")
    func relaunchNow() {
        let presenter = RecordingPresenter()
        let coordinator = PendingUpdateCoordinator(presenter: presenter)
        var installs = 0
        coordinator.updateReady(prompt) { installs += 1 }
        #expect(presenter.shown.count == 1)
        #expect(presenter.shown.first?.prompt == prompt)
        #expect(installs == 0, "nothing relaunches until the person says so")
        presenter.shown[0].relaunch()
        #expect(installs == 1)
        #expect(presenter.dismissals == 1)
    }

    @Test("Later closes the prompt without installing, and asking for updates brings it back")
    func later() {
        let presenter = RecordingPresenter()
        let coordinator = PendingUpdateCoordinator(presenter: presenter)
        var installs = 0
        #expect(!coordinator.remindIfPending(), "nothing is waiting yet")
        coordinator.updateReady(prompt) { installs += 1 }
        presenter.shown[0].later()
        #expect(installs == 0)
        #expect(presenter.dismissals == 1)
        #expect(coordinator.hasPendingUpdate, "Sparkle still installs it when Hushy quits")
        #expect(coordinator.remindIfPending())
        #expect(presenter.shown.count == 2)
        presenter.shown[1].relaunch()
        #expect(installs == 1)
    }

    // MARK: Build defaults

    @Test("the app's Info.plist checks and installs updates automatically, with no permission prompt")
    func infoPlistDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool != false)
    }
}
