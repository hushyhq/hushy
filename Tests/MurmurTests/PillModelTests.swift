import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The idle pill's hover-driven presentation lives on `PillModel` (not in `PillView` state) so
/// it can be tested: which hint label shows, whether the format chip shows, and what it says.
@Suite("Pill model — idle hover, hint label, format chip")
@MainActor
struct PillModelTests {
    private let modes = [
        (id: UUID(), name: "Email", icon: "envelope"),
        (id: UUID(), name: "Message", icon: "message"),
    ]

    // MARK: Hint label (one label, never two tooltips)

    @Test("the hint reads Dictate + trigger key when nothing specific is hovered")
    func hintAtRest() {
        let model = PillModel()
        model.triggerGlyph = "fn"
        model.isHovered = true
        #expect(model.idleHint == PillModel.IdleHint(title: "Dictate", keys: ["fn"]))
    }

    @Test("hovering the mic keeps the Dictate hint")
    func hintOverMic() {
        let model = PillModel()
        model.isHovered = true
        model.hoveredIdleControl = .dictate
        #expect(model.idleHint.title == "Dictate")
        #expect(model.idleHint.keys == ["fn"])
    }

    @Test("hovering the action button swaps the hint to Action ×2 + the chosen action key, whatever the dictation key")
    func hintOverAction() {
        let model = PillModel()
        model.triggerGlyph = "⌥"
        model.isHovered = true
        model.hoveredIdleControl = .action
        // It follows the action key setting (control by default), never the dictation trigger.
        #expect(model.idleHint == PillModel.IdleHint(title: "Action ×2", keys: ["control"]))
    }

    @Test("moving mic → action → mic swaps the single hint back and forth")
    func hintFollowsPointer() {
        let model = PillModel()
        model.isHovered = true
        model.hoveredIdleControl = .dictate
        model.hoveredIdleControl = .action
        #expect(model.idleHint.title == "Action ×2")
        model.hoveredIdleControl = .dictate
        #expect(model.idleHint.title == "Dictate")
    }

    @Test("leaving the pill clears the hovered control so nothing stays focused")
    func leavingClearsControl() {
        let model = PillModel()
        model.isHovered = true
        model.hoveredIdleControl = .action
        model.isHovered = false
        #expect(model.hoveredIdleControl == nil)
        #expect(model.idleHint.title == "Dictate")
    }

    // MARK: Format chip

    @Test("no chip when no modes are wired up, even if a mode is reported active")
    func chipHiddenWithoutModes() {
        let model = PillModel()
        model.activeMode = PillModel.ActiveMode(name: "Email", isManualOverride: true)
        #expect(model.showsModeChip == false)
    }

    @Test("no chip when nothing is forced (automatic per-app formatting)")
    func chipHiddenWhenAutomatic() {
        let model = PillModel()
        model.modeChoices = modes
        model.activeMode = nil
        #expect(model.showsModeChip == false)
        #expect(model.modeChipLabel == nil)
        #expect(model.canResetMode == false)
    }

    @Test("a one-shot override shows 'Format: <mode>' and offers Automatic")
    func chipForManualOverride() {
        let model = PillModel()
        model.modeChoices = modes
        model.activeMode = PillModel.ActiveMode(name: "Email", isManualOverride: true)
        #expect(model.showsModeChip)
        #expect(model.modeChipLabel == "Format: Email")
        #expect(model.canResetMode)
    }

    @Test("an app-assigned mode shows the chip but has nothing to reset")
    func chipForAppAssignment() {
        let model = PillModel()
        model.modeChoices = modes
        model.activeMode = PillModel.ActiveMode(name: "Message", isManualOverride: false)
        #expect(model.showsModeChip)
        #expect(model.modeChipLabel == "Format: Message")
        #expect(model.canResetMode == false)
    }

    // MARK: AppModel → chip mapping

    @Test("the Default fallback maps to no chip; anything else maps to its name and source")
    func chipModeMapping() {
        let builtIns = Mode.builtIns(userName: "")
        let defaultMode = builtIns.first { $0.id == Mode.BuiltInID.default }!
        let email = builtIns.first { $0.id == Mode.BuiltInID.email }!

        #expect(AppModel.chipMode(defaultMode, isManualOverride: false) == nil)
        #expect(AppModel.chipMode(email, isManualOverride: false)
            == PillModel.ActiveMode(name: "Email", isManualOverride: false))
        #expect(AppModel.chipMode(email, isManualOverride: true)
            == PillModel.ActiveMode(name: "Email", isManualOverride: true))
        // Explicitly picking Default for one dictation is a real choice: show it, resettable.
        #expect(AppModel.chipMode(defaultMode, isManualOverride: true)
            == PillModel.ActiveMode(name: "Default", isManualOverride: true))
    }
}
