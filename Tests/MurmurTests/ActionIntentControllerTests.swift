import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Task 135, the founder's direction: for a voice action the person started on purpose, no rule
/// decides intent. A rule may say yes to something it recognises (open <app>, a question shape);
/// everything else reaches the model, and never ends in "didn't understand" or "couldn't find"
/// without the model having been asked.
@Suite("Action intent: rules say yes, the model decides the rest")
@MainActor
struct ActionIntentControllerTests {
    @MainActor final class Box { var items: [String] = [] }

    private func rig(heard: String) throws -> (rig: VoiceActionOutcomeTests.Rig, asked: Box) {
        let rig = try VoiceActionOutcomeTests.Rig()
        let asked = Box()
        rig.controller.insertFallbackText = { _ in }
        rig.controller.transcribeSamples = { _ in heard }
        rig.controller.extract = { text, _ in
            asked.items.append(text)
            return ActionExtractor.Output(result: .notAnAction, usedModel: true)
        }
        return (rig, asked)
    }

    @Test("a sentence no rule recognises reaches the model, whatever it looks like", arguments: [
        "Why didn't my reminder go off yesterday?",
        "She said she would schedule the flight for us.",
        "Could you imagine scheduling forty meetings in one week",
        "Can you hear me okay?",
        "Do you think a calendar event would work better than a reminder?",
        "Would you mind putting the book club on my calendar?",
        "Do you mind adding oat milk to my groceries list?",
        "start working on the quarterly planning document",
    ])
    func reachesTheModel(_ heard: String) async throws {
        let (rig, asked) = try rig(heard: heard)
        await rig.controller.process([0.1], followUp: nil)
        #expect(asked.items == [heard], "a rule ended it before the model was asked: \(heard)")
    }

    @Test("a follow-up no rule recognises is put to the model, which decides if it is a question")
    func followUpReachesTheModel() async throws {
        let (rig, asked) = try rig(heard: "unused")
        let card = AnswerCardState(question: "what groceries do i need", phase: .thinking)
        rig.pill.state = .answer(card)
        await rig.controller.followUpDo("Could you also get coffee?", after: card)
        #expect(asked.items == ["Could you also get coffee?"])
    }

    // MARK: Open <app> is recognised only when something on this Mac could be it

    private func appsFolder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)", isDirectory: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).app", isDirectory: true), withIntermediateDirectories: true)
        }
        return folder
    }

    @Test("an app that is installed, or close to one, is recognised; a sentence that resembles none is not")
    func recognisesApps() throws {
        let folder = try appsFolder(["Notion", "Figma", "Linear"])
        defer { try? FileManager.default.removeItem(at: folder) }
        func recognised(_ name: String) -> Bool {
            WorkspaceLinkBackend.recognisesApp(heard: name, running: [], folders: [folder])
        }
        #expect(recognised("Notion"))
        #expect(recognised("Figma"))
        #expect(recognised("Notian"), "a near miss still gets the did-you-mean card")
        #expect(!recognised("Working On The Quarterly Planning Document"))
        #expect(!recognised("A Timer For Five Minutes"))
    }
}
