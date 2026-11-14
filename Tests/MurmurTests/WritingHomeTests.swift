import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// One place sets how Hushy writes: Voice & style, on its Style section. Settings → Writing points
/// there instead of repeating its controls.
@Suite("Writing home")
struct WritingHomeTests {
    @Test("the pointer lands on Voice & style, on the section that holds the tone")
    func pointerTarget() {
        #expect(WritingHome.section == .style)
        #expect(WritingHome.tab == .style)
        #expect(VoiceAndStyleView.Tab.allCases.first == WritingHome.tab)
    }

    @Test("a request to show a section carries that section, and nothing else is read as one")
    func requestCarriesTheSection() {
        for tab in VoiceAndStyleView.Tab.allCases {
            #expect(WritingHome.tab(in: Notification(name: WritingHome.show, object: tab)) == tab)
        }
        #expect(WritingHome.tab(in: Notification(name: WritingHome.show, object: nil)) == nil)
        #expect(WritingHome.tab(in: Notification(name: WritingHome.show, object: "style")) == nil)
    }
}
