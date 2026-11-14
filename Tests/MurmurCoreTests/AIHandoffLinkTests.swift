import Foundation
import Testing
@testable import MurmurCore

@Suite("AIHandoffLink", .serialized)   // the service flags are shared statics; parallel cases race on them
struct AIHandoffLinkTests {
    private func handoffAction(service: AIHandoffLink.Service, question: String = "why") -> ProposedAction {
        let url = AIHandoffLink.build(service: service, question: question)!.url.absoluteString
        return ProposedAction(kind: .openLink, title: "Ask \(service.displayName)", url: url, sourceText: "")
    }

    @Test("fill-only hand-offs never say Asked on the done chip", arguments: AIHandoffLink.Service.allCases)
    func fillOnlyDoneChip(service: AIHandoffLink.Service) {
        defer { resetSubmitFlags() }
        setSubmitFlag(service, false)
        let title = ActionDispatch.doneTitle(for: handoffAction(service: service))
        #expect(!title.contains("Asked"))
        #expect(title == AIHandoffLink.doneChipTitle(service: service))
        #expect(title.contains("press ↩"))
    }

    @Test("verified hand-offs may say Asked", arguments: AIHandoffLink.Service.allCases)
    func autoSubmitDoneChip(service: AIHandoffLink.Service) {
        defer { resetSubmitFlags() }
        setSubmitFlag(service, true)
        #expect(ActionDispatch.doneTitle(for: handoffAction(service: service)) == "Asked \(service.displayName)")
    }

    @Test("submit stays draft until the service flag is true", arguments: AIHandoffLink.Service.allCases)
    func submitRule(service: AIHandoffLink.Service) {
        defer { resetSubmitFlags() }
        setSubmitFlag(service, false)
        let action = handoffAction(service: service)
        #expect(ActionPolicy.submit(for: action) == .draftOnly)
        #expect(!ActionPolicy.mayPressReturn(for: action))
        setSubmitFlag(service, true)
        #expect(ActionPolicy.submit(for: action) == .autoSubmit)
        #expect(ActionPolicy.mayPressReturn(for: action))
    }

    @Test("History uses the same honest line as the done chip")
    func historyLine() {
        defer { resetSubmitFlags() }
        let action = handoffAction(service: .claude, question: "sky")
        let done = ActionDispatch.doneTitle(for: action)
        let record = ActionRecord(
            createdAt: Date(), kind: .openLink, title: done, detail: "claude.ai", sourceText: "", status: .completed)
        #expect(ActionRecordLine.text(for: record) == "\(done) \u{00B7} claude.ai")
        #expect(!ActionRecordLine.text(for: record).contains("Asked"))
    }

    private func setSubmitFlag(_ service: AIHandoffLink.Service, _ value: Bool) {
        switch service {
        case .claude: AIHandoffLink.Service.claudeLinkSubmitsAutomatically = value
        case .chatgpt: AIHandoffLink.Service.chatgptLinkSubmitsAutomatically = value
        case .perplexity: AIHandoffLink.Service.perplexityLinkSubmitsAutomatically = value
        case .gemini: AIHandoffLink.Service.geminiLinkSubmitsAutomatically = value
        }
    }

    private func resetSubmitFlags() {
        AIHandoffLink.Service.claudeLinkSubmitsAutomatically = false
        AIHandoffLink.Service.chatgptLinkSubmitsAutomatically = false
        AIHandoffLink.Service.perplexityLinkSubmitsAutomatically = false
        AIHandoffLink.Service.geminiLinkSubmitsAutomatically = false
    }
}
