import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// The Assistant column's collapse state (⌥⌘0) and its action-items fold persist in
/// `AppSettings`, defaulting to expanded. Uses a throwaway `UserDefaults` suite.
@Suite("Assistant settings")
@MainActor
struct AssistantSettingsTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "hushy-test-assistant-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("the Assistant column starts expanded")
    func defaultsExpanded() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.assistantCollapsed == false)
        #expect(settings.assistantActionItemsCollapsed == false)
    }

    @Test("collapsing is remembered across launches")
    func persists() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.assistantCollapsed = true
        settings.assistantActionItemsCollapsed = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.assistantCollapsed)
        #expect(reloaded.assistantActionItemsCollapsed)
        reloaded.assistantCollapsed.toggle()
        #expect(AppSettings(defaults: defaults).assistantCollapsed == false)
    }

    @Test("the Assistant is off by default, with no consent and Haiku selected")
    func optInDefaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.assistantEnabled == false)
        #expect(settings.assistantConsentVersion == 0)
        #expect(settings.assistantModel == .haiku)
        settings.assistantModel = .sonnet
        #expect(AppSettings(defaults: defaults).assistantModel == .sonnet)
    }

    @Test("turning on asks for consent once; accepting records its version; off stops")
    func consentFlow() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let model = AssistantModel(settings: settings, store: try Store(), makeBridge: { AgentChatBridge(locate: { _ in nil }, serverPath: nil) })
        model.requestEnable(from: .home)
        #expect(model.consentHost == .home)
        #expect(!settings.assistantEnabled, "nothing turns on before consent")
        model.declineConsent()
        #expect(model.consentHost == nil)
        #expect(!settings.assistantEnabled)
        model.requestEnable(from: .settings)
        model.acceptConsent()
        #expect(settings.assistantEnabled)
        #expect(settings.assistantConsentVersion == AssistantConsent.currentVersion)
        model.disable()
        #expect(!settings.assistantEnabled)
        model.requestEnable(from: .home)
        #expect(model.consentHost == nil, "consent already given for this version")
        #expect(settings.assistantEnabled)
    }

    @Test("the assistant model refuses to send when off or nothing is connected")
    func assistantModelGuards() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AssistantModel(
            settings: AppSettings(defaults: defaults), store: try Store(),
            makeBridge: { AgentChatBridge(locate: { _ in nil }, serverPath: nil) })
        model.pinForSnapshot(installed: [.claudeCode], messages: [], enabled: false)
        #expect(!model.isConnected, "off by default")
        #expect(!model.send("hello"))
        model.pinForSnapshot(installed: [], messages: [])
        #expect(!model.isConnected)
        #expect(!model.send("hello"))
        model.pinForSnapshot(installed: [.codex], messages: [])
        #expect(!model.isConnected, "Codex is listed but not supported yet")
        model.pinForSnapshot(installed: [.claudeCode], messages: [], signedOut: [.claudeCode])
        #expect(!model.isConnected, "signed out")
        model.pinForSnapshot(installed: [.claudeCode, .codex], messages: [])
        #expect(model.isConnected)
        #expect(model.showsAgentPicker)
        #expect(!model.send("   "))
    }
}
