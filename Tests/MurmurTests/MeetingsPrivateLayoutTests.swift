import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// What a release build shows with meetings private (TRY-98): no Notes section, no Notes & meetings
/// settings, and no copy about notes, meetings or the Assistant. The functions take the flag as an
/// argument so both layouts can be checked in a debug build.
@MainActor
@Suite("Meetings private layout")
struct MeetingsPrivateLayoutTests {
    @Test("sections: Notes is there with meetings on and gone with them off")
    func sections() {
        #expect(AppModel.Section.available(meetings: true).contains(.notes))
        let release = AppModel.Section.available(meetings: false)
        #expect(!release.contains(.notes))
        #expect(release == [.home, .history, .insights, .style, .ai])
    }

    @Test("settings: the preview switch cannot bring Notes & meetings back when meetings are private")
    func settingsPanes() {
        #expect(SettingsPane.visible(showsNotesAndMeetings: true, meetings: true).contains(.notesAndMeetings))
        #expect(!SettingsPane.visible(showsNotesAndMeetings: true, meetings: false).contains(.notesAndMeetings))
        #expect(!SettingsPane.visible(showsNotesAndMeetings: false, meetings: true).contains(.notesAndMeetings))
    }

    @Test("copy: nothing a release build says mentions notes, meetings or the Assistant")
    func releaseCopy() {
        let lines = AIConnectView.prompts(meetings: false)
            + [AIConnectionsCopy.scopeDetail(meetings: false), PrivacySettingsPane.networkText(meetings: false)]
        for line in lines {
            for word in ["meeting", "notes", "Assistant", "action item"] {
                #expect(!line.localizedCaseInsensitiveContains(word), "“\(line)” mentions \(word)")
            }
        }
        #expect(AIConnectionsCopy.scopeDetail(meetings: false).contains("dictation history"))
    }

    @Test("copy: with meetings on the words are what they were")
    func debugCopy() {
        #expect(AIConnectionsCopy.scopeDetail(meetings: true).contains("notes and meetings"))
        #expect(PrivacySettingsPane.networkText(meetings: true).contains("Connected AI apps and the Assistant"))
        #expect(AIConnectView.prompts(meetings: true).count > AIConnectView.prompts(meetings: false).count)
    }

    @Test("the default arguments follow the flag, which is on in a debug build")
    func defaultsFollowFlag() {
        #expect(AppModel.Section.available() == AppModel.Section.available(meetings: true))
        #expect(AIConnectionsCopy.connectorScopeDetail == AIConnectionsCopy.scopeDetail(meetings: true))
    }

    @Test("AI apps read no notes whether or not meetings are on (the connector copy now names more than they can read)")
    func copyNeverOverstatesTools() {
        for meetings in [true, false] {
            let names = MCPServer.toolNames(for: .all, exposesNotes: meetings)
            #expect(MCPServer.noteToolNames.isDisjoint(with: names))
            #expect(names == ["get_insights"])
        }
    }

    @Test("own-stuff search skips notes when meetings are private")
    func ownStuffSkipsNotes() async throws {
        let store = try Store()
        _ = try store.save(Note(title: "Pricing sync", transcript: "pricing budget", summary: "s", status: .ready))
        let query = OwnStuffQuery(
            question: "what about the pricing sync", context: DateContext(now: Date(), timeZone: TimeZone(identifier: "UTC")!))
        var source = StoreOwnStuffSource(store: store)
        source.includesNotes = true
        #expect(await source.search(query).contains { $0.kind == .note })
        source.includesNotes = false
        #expect(await source.search(query).allSatisfy { $0.kind != .note })
    }
}
