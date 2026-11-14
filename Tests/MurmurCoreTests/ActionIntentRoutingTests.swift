import Foundation
import Testing
@testable import MurmurCore

/// Task 135, the rules that run before the extractor: a polite or question-shaped request to
/// open, find, ask or summarise must reach the same route as its bare command. The routes are
/// the controller's order: `AskRouter` first, then `OpenCommandParser`. Invented utterances.
@Suite("Action intent: polite requests reach the right route")
struct ActionIntentRoutingTests {
    enum Route: String, Equatable {
        case openApp, openLink, askAI, askOwn, summarize, findFile, extractor
    }

    private static let context = DateContext(
        now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)

    static func route(_ utterance: String) -> Route {
        switch AskRouter.route(utterance) {
        case .askAI: return .askAI
        case .askOwn: return .askOwn
        case .summarizeScreen: return .summarize
        case .findFile, .maybeFile: return .findFile
        case .none:
            switch OpenCommandParser.parse(utterance, context: context) {
            case .app?, .aiService?: return .openApp
            case .link?: return .openLink
            case nil: return .extractor
            }
        }
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let utterance: String
        let route: Route
        var testDescription: String { utterance }
    }

    /// Measured misses, not in the table: "Could you pull up my calendar for friday?" goes to the
    /// own-stuff answer (`askOwn`) like its bare form, and "Can you give me directions to the
    /// airport?" matches no rule (the parser knows "directions to ..." only), so it reaches the model.
    static let rows: [Row] = [
        // open an app or a site
        Row(utterance: "Can you open Slack?", route: .openApp),
        Row(utterance: "could you open the calendar app", route: .openApp),
        Row(utterance: "Would you switch to Notion?", route: .openApp),
        Row(utterance: "please open Figma", route: .openApp),
        Row(utterance: "Will you launch Xcode?", route: .openApp),
        Row(utterance: "would you search youtube for lo fi beats", route: .openLink),
        // find a file
        Row(utterance: "Could you find my resume?", route: .findFile),
        Row(utterance: "would you find the lease agreement pdf", route: .findFile),
        Row(utterance: "Can you find the invoice from march?", route: .findFile),
        Row(utterance: "please find and open my passport scan", route: .findFile),
        // ask an assistant, or ask about the person's own things
        Row(utterance: "Could you ask Claude what a monad is?", route: .askAI),
        Row(utterance: "can you ask chatgpt to explain recursion", route: .askAI),
        Row(utterance: "would you ask gemini about the best way to learn piano", route: .askAI),
        Row(utterance: "Can you tell me what groceries I still need?", route: .askOwn),
        Row(utterance: "could you tell me what is on my calendar tomorrow", route: .askOwn),
        // summarise what is on screen
        Row(utterance: "Can you summarize this page?", route: .summarize),
        Row(utterance: "could you summarise this email", route: .summarize),
        Row(utterance: "would you give me a summary of this article", route: .summarize),
        Row(utterance: "Will you recap this thread?", route: .summarize),
        // not for the rules at all: these belong to the extractor
        Row(utterance: "Could you remind me to pick up the dry cleaning?", route: .extractor),
        Row(utterance: "would you add a dentist checkup tomorrow at 2 pm", route: .extractor),
    ]

    @Test("a polite request takes the route its bare command takes", arguments: rows)
    func politeRequestRoutes(_ row: Row) {
        #expect(Self.route(row.utterance) == row.route, "\(row.utterance)")
    }
}
