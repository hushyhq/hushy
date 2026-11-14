import Foundation
import Testing
@testable import Murmur

/// The sidebar's lower band: profile copy and readiness visibility.
@Suite("Sidebar — profile and readiness")
struct SidebarRowsTests {
    @Test("the profile row shows the name, or You until one is set")
    func profileTitle() {
        #expect(SidebarProfile.title(name: "Ada") == "Ada")
        #expect(SidebarProfile.title(name: "  ") == "You")
        #expect(SidebarProfile.initial(name: "ada") == "A")
        #expect(SidebarProfile.initial(name: "") == nil)
    }

    @Test("the profile line reads Founding member or Free, never a paid plan")
    func planLine() {
        #expect(SidebarProfile.planLine(isFoundingMember: true) == "Founding member")
        #expect(SidebarProfile.planLine(isFoundingMember: false) == "Free")
    }

    @Test("ready has no dead sidebar row; blocked states retain their fix")
    func readinessRow() {
        let ready = DictationReadinessStatus(kind: .ready, text: "Ready", detail: "Ready", fix: nil, reason: .ready)
        let blocked = DictationReadinessStatus(kind: .error, text: "Microphone access needed", detail: "Allow access", fix: .requestMicrophone, reason: .microphoneNotAsked)
        #expect(!SidebarReadiness.showsRow(ready))
        #expect(SidebarReadiness.showsRow(blocked))
        #expect(blocked.fix == .requestMicrophone)
    }
}
