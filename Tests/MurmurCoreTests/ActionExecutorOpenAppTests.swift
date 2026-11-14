import Foundation
import Testing
@testable import MurmurCore

@Suite("Opening an app: the closest installed apps travel with the error")
struct ActionExecutorOpenAppTests {
    private func executor(_ links: FakeLinkBackend) -> ActionExecutor {
        ActionExecutor(calendar: FakeCalendarBackend(), shortcuts: FakeShortcutsBackend(), links: links)
    }

    @Test("an app with close matches throws them, not a dead end")
    func closestAppsPropagate() async {
        let links = FakeLinkBackend()
        await links.setNextError(.closestApps(heard: "wen", apps: ["Wendy", "Zen"]))
        let action = ProposedAction(kind: .openLink, title: "Open wen", appName: "wen", sourceText: "open wen")
        await #expect(throws: ActionExecutionError.closestApps(heard: "wen", apps: ["Wendy", "Zen"])) {
            _ = try await executor(links).execute(action)
        }
        #expect(await links.opened.isEmpty)
    }

    @Test("an AI service with close app names still falls back to its site")
    func serviceFallsBackToSite() async throws {
        let links = FakeLinkBackend()
        await links.setNextError(.closestApps(heard: "ChatGPT", apps: ["ChatGPT Atlas"]))
        let action = ProposedAction(
            kind: .openLink, title: "Open ChatGPT", appName: "ChatGPT", url: "https://chatgpt.com", sourceText: "open chatgpt")
        _ = try await executor(links).execute(action)
        #expect(await links.opened == [.url(URL(string: "https://chatgpt.com")!, browser: nil)])
    }

    @Test("a missing app with a site still falls back to the site")
    func missingAppFallsBack() async throws {
        let links = FakeLinkBackend()
        await links.setNextError(.notFound("ChatGPT"))
        let action = ProposedAction(
            kind: .openLink, title: "Open ChatGPT", appName: "ChatGPT", url: "https://chatgpt.com", sourceText: "open chatgpt")
        _ = try await executor(links).execute(action)
        #expect(await links.opened == [.url(URL(string: "https://chatgpt.com")!, browser: nil)])
    }
}

private extension FakeLinkBackend {
    func setNextError(_ error: ActionExecutionError) { nextError = error }
}
