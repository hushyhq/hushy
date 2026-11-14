import Foundation
import Testing
@testable import MurmurCore

@Suite("HistoryAppChipModel")
struct HistoryAppChipModelTests {
    private let counts = [
        Store.AppDictationCount(bundleID: "com.anthropic.claude", appName: "Claude", count: 79),
        Store.AppDictationCount(bundleID: "com.mitchellh.ghostty", appName: nil, count: 12),
    ]

    @Test("All apps comes first and carries no number")
    func allAppsFirst() {
        let all = HistoryAppChipModel.chips(from: counts).first!
        #expect(all.isAllApps)
        #expect(all.name == "All apps")
        #expect(all.accessibilityLabel == "All apps")
    }

    @Test("per-app chips keep usage order, fall back to the bundle id for a name, and speak just the name")
    func perAppChips() {
        let chips = HistoryAppChipModel.chips(from: counts).dropFirst()
        #expect(chips.map(\.name) == ["Claude", "com.mitchellh.ghostty"])
        #expect(chips.first?.accessibilityLabel == "Claude")
    }

    @Test("no apps still yields the All apps chip")
    func empty() {
        let chips = HistoryAppChipModel.chips(from: [])
        #expect(chips.count == 1)
        #expect(chips.first?.isAllApps == true)
    }
}
