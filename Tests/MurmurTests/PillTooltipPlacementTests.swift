import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Murmur

/// The pill's hover hint: one compact row, centred on the button it describes, 8 pt clear of it,
/// kept inside the panel (UI round 2026-09-28 follow-up).
@Suite("Pill tooltip — one row, centred on its button")
struct PillTooltipPlacementTests {
    private let panel = CGSize(width: 280, height: 104)
    private let bubble = CGSize(width: 70, height: 20)

    @Test("centred on the button, 8 pt above it")
    func aboveButton() {
        let cancel = CGRect(x: 105, y: 79, width: 20, height: 20)
        let centre = PillTooltipPlacement.centre(button: cancel, bubble: bubble, container: panel, opensDownward: false)
        #expect(centre.x == cancel.midX)
        #expect(centre.y == cancel.minY - 8 - bubble.height / 2)
    }

    @Test("at the top edge it hangs 8 pt below the button")
    func belowButton() {
        let button = CGRect(x: 105, y: 5, width: 20, height: 20)
        let centre = PillTooltipPlacement.centre(button: button, bubble: bubble, container: panel, opensDownward: true)
        #expect(centre.y == button.maxY + 8 + bubble.height / 2)
    }

    @Test("a button near the panel edge keeps the whole hint inside the panel")
    func clamped() {
        let nearRight = CGRect(x: 250, y: 79, width: 20, height: 20)
        let wide = CGSize(width: 130, height: 20)
        let centre = PillTooltipPlacement.centre(button: nearRight, bubble: wide, container: panel, opensDownward: false)
        #expect(centre.x + wide.width / 2 <= panel.width - 4)
        let nearLeft = CGRect(x: 2, y: 79, width: 20, height: 20)
        #expect(PillTooltipPlacement.centre(button: nearLeft, bubble: wide, container: panel, opensDownward: false).x
                - wide.width / 2 >= 4)
    }

    @Test("hint text is one row: words and key caps", arguments: [
        ("Cancel [esc]", ["Cancel", "[esc]"]),
        ("Done [⏎]", ["Done", "[⏎]"]),
        ("Stop and save", ["Stop and save"]),
    ])
    func tokens(text: String, expected: [String]) {
        let rendered = TooltipBubble.tokens(text).map { $0.isKey ? "[\($0.text)]" : $0.text }
        #expect(rendered == expected)
        #expect(!text.contains("\n"))
    }

    @Test("the pointer notch sits under the button even when the hint is pushed inside the panel")
    func notchFollowsButton() {
        let nearRight = CGRect(x: 250, y: 79, width: 20, height: 20)
        let wide = CGSize(width: 130, height: 34)
        let centre = PillTooltipPlacement.centre(button: nearRight, bubble: wide, container: panel, opensDownward: false)
        let offset = PillTooltipPlacement.notchOffset(button: nearRight, centre: centre, bubbleWidth: wide.width)
        #expect(centre.x + offset == nearRight.midX)
        let farOut = PillTooltipPlacement.notchOffset(button: CGRect(x: 900, y: 0, width: 20, height: 20),
                                                      centre: centre, bubbleWidth: wide.width)
        #expect(abs(farOut) <= wide.width / 2 - 14, "the notch never leaves the capsule's straight edge")
    }

    @Test("each pill button's hint: one word, its key, and a secondary only on ✓")
    func hints() {
        #expect(PillHint.cancel.title == "Cancel")
        #expect(PillHint.cancel.key == "esc")
        #expect(PillHint.finish.title == "Done")
        #expect(PillHint.finish.key == "⏎")
        #expect(PillHint.finish == PillHint(title: "Done", key: "⏎"), "just \"Done\": there is no paste-and-send")
        #expect(!PillHint.finish.compact.contains("\n"))
    }

    @Test("hint states get a panel wide enough that no hint variant is clipped")
    @MainActor func hintPanelWidth() {
        for state: PillState in [.handsFree(startedAt: .now), .recordingNote(startedAt: .now), .actionListening] {
            #expect(PillPanel.size(for: state).width >= 420)
            #expect(PillPanel.size(for: state).height == PillPanel.size.height)
        }
        #expect(PillPanel.size(for: .idle) == PillPanel.size, "idle keeps its small panel")
    }

    @Test("the final rim style: a lit 1 pt rim with a tight glow, never a halo; subtler in light mode")
    func rimGlow() {
        let dark = PillHintBubble.rimGlow(hostScheme: .dark)
        let light = PillHintBubble.rimGlow(hostScheme: .light)
        #expect(PillHintBubble.rimWidth == 1)
        #expect(dark.radius >= 2 && dark.radius <= 4)
        #expect(light.radius <= dark.radius)
        #expect(light.opacity < dark.opacity / 2)
        #expect(PillHintStyle.rim.showsKeys == false)
        #expect(PillHintStyle.tintedKeys.showsKeys)
    }

    @Test("a hint beside a vertical side pill stays inside a narrow panel horizontally too", arguments: [true, false])
    func besideClampedHorizontally(toRight: Bool) {
        let narrow = CGSize(width: 180, height: 200)
        let long = CGSize(width: 160, height: 34)
        let button = CGRect(x: toRight ? 20 : 140, y: 80, width: 20, height: 20)
        let centre = PillTooltipPlacement.centreBeside(button: button, bubble: long, container: narrow, toRight: toRight)
        #expect(centre.x - long.width / 2 >= PillTooltipPlacement.margin)
        #expect(centre.x + long.width / 2 <= narrow.width - PillTooltipPlacement.margin)
        #expect(centre.y == button.midY)
    }
}
