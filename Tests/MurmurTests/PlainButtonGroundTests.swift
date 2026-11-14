import AppKit
import MurmurCore
import SwiftUI
import Testing
@testable import Murmur

/// A plain button takes clicks only where its label draws something. These are the buttons whose
/// label is stretched or padded over a ground that is clear until the button is selected or
/// hovered: each must take a click on its whole shape, not only on its words or its glyph.
/// Real views in a window far off every screen, real mouse events (`ClickHost`).
@MainActor
@Suite("Plain buttons with a clear ground take a click on their whole shape", .serialized)
struct PlainButtonGroundTests {
    @MainActor
    @Observable
    final class Taps {
        var tab: VoiceAndStyleView.Tab = .style
        var count = 0
    }

    private static let stripSize = NSSize(width: 700, height: 46)

    struct SectionStrip: View {
        @Bindable var taps: Taps

        var body: some View {
            HStack(spacing: 2) {
                ForEach(VoiceAndStyleView.Tab.allCases) { item in
                    VoiceStyleTab(item: item, isSelected: taps.tab == item, showsSymbol: true) { taps.tab = item }
                }
            }
            .padding(4)
            .frame(width: PlainButtonGroundTests.stripSize.width, height: PlainButtonGroundTests.stripSize.height)
        }
    }

    @Test("Voice & style's section tabs: a click near a tab's edge, away from its words, opens that section",
          arguments: VoiceAndStyleView.Tab.allCases)
    func sectionTab(tab: VoiceAndStyleView.Tab) throws {
        let taps = Taps()
        let host = ClickHost(SectionStrip(taps: taps), size: Self.stripSize)
        defer { host.close() }
        let all = VoiceAndStyleView.Tab.allCases
        let index = try #require(all.firstIndex(of: tab))
        let width = (Self.stripSize.width - 8 - 2 * CGFloat(all.count - 1)) / CGFloat(all.count)
        let minX = 4 + CGFloat(index) * (width + 2)
        let points = [
            ("its left edge", CGPoint(x: minX + 5, y: Self.stripSize.height / 2)),
            ("its right edge", CGPoint(x: minX + width - 5, y: Self.stripSize.height / 2)),
            ("above its words", CGPoint(x: minX + width / 2, y: 8)),
        ]
        for (name, point) in points {
            taps.tab = all.first { $0 != tab } ?? .style
            host.settle(0.1)
            host.click(point)
            #expect(taps.tab == tab, "\(tab.rawValue): a click on \(name) at \(point) left \(taps.tab.rawValue) open")
        }
    }

    @Test("a settings sidebar row that is not selected takes a click on its empty right end")
    func sidebarRow() throws {
        let taps = Taps()
        let pane = try #require(SettingsPane.allCases.first)
        let size = NSSize(width: 220, height: 34)
        let host = ClickHost(
            SettingsSidebarRow(pane: pane, isSelected: false) { taps.count += 1 }.frame(width: size.width, height: size.height),
            size: size)
        defer { host.close() }
        host.click(CGPoint(x: size.width - 12, y: size.height / 2))
        #expect(taps.count == 1)
    }

    @Test("an icon button takes a click inside its circle, beside the glyph, before any hover")
    func iconButton() {
        let taps = Taps()
        let size = NSSize(width: 26, height: 26)
        let host = ClickHost(IconButton(symbol: "xmark", help: "Close") { taps.count += 1 }, size: size)
        defer { host.close() }
        host.click(CGPoint(x: 4, y: size.height / 2))
        #expect(taps.count == 1)
    }

    @Test("the retry button takes a click inside its circle, beside the glyph, before any hover")
    func retryButton() {
        let taps = Taps()
        let size = NSSize(width: 26, height: 26)
        let host = ClickHost(RetryButton(isRetrying: false) { taps.count += 1 }, size: size)
        defer { host.close() }
        host.click(CGPoint(x: 4, y: size.height / 2))
        #expect(taps.count == 1)
    }
}
