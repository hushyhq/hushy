import CoreGraphics
import Testing
@testable import Murmur

@Suite("Detail layout")
struct DetailLayoutTests {
    private func sectionWidth(window: CGFloat, collapsedSidebar: Bool) -> CGFloat {
        window - (collapsedSidebar ? AssistantPane.collapsedSidebarWidth : AssistantPane.sidebarWidth)
            - 0.5 - AssistantPane.width
    }

    @Test("History with Assistant open at fitting, threshold, and roughly 1,000 point windows")
    func historyWidths() {
        let wide = sectionWidth(window: 1600, collapsedSidebar: false)
        #expect(DetailLayout.decide(available: wide, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: false)
                == .split(listWidth: 620, detailWidth: 343.5))

        let edge = sectionWidth(window: 1316, collapsedSidebar: false)
        #expect(DetailLayout.decide(available: edge, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: false) == .listOnly)
        #expect(DetailLayout.decide(available: edge, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: true) == .detailOnly)

        let narrow = sectionWidth(window: 1010, collapsedSidebar: true)
        #expect(AssistantPane.hasRoom(windowWidth: 1010, sidebarCollapsed: true))
        #expect(DetailLayout.decide(available: narrow, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: true) == .detailOnly)
        #expect(DetailLayout.decide(available: narrow, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: true, showSelectedDetail: false) == .listOnly)
    }

    @Test("History clamps a saved list width before detail becomes too narrow")
    func savedWidth() {
        #expect(DetailLayout.decide(available: 900, preferredList: 780, minimumList: 360,
                                    minimumDetail: 320, hasSelection: true)
                == .split(listWidth: 572, detailWidth: 320))
        #expect(DetailLayout.decide(available: 688, preferredList: 620, minimumList: 360,
                                    minimumDetail: 320, hasSelection: true)
                == .split(listWidth: 360, detailWidth: 320))
    }

    @Test("Notes list and detail never become slivers")
    func notesWidths() {
        #expect(DetailLayout.decide(available: 720.5, preferredList: 300, minimumList: 300,
                                    minimumDetail: 420, hasSelection: true, dividerWidth: 0.5)
                == .split(listWidth: 300, detailWidth: 420))
        #expect(DetailLayout.decide(available: 720, preferredList: 300, minimumList: 300,
                                    minimumDetail: 420, hasSelection: false, dividerWidth: 0.5) == .listOnly)
        #expect(DetailLayout.decide(available: 720, preferredList: 300, minimumList: 300,
                                    minimumDetail: 420, hasSelection: true, dividerWidth: 0.5) == .detailOnly)
    }
}
