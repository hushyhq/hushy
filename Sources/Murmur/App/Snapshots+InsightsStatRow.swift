import SwiftUI

extension Snapshots {
    /// The Insights headline row with a long "saved" figure ("1,240 min") and the longer
    /// footnote, at the narrowest window the app allows (960 pt: minus the 248 pt sidebar and
    /// the page's side padding) and at a roomy one. The "Measure again" link must sit in the
    /// card's flow, clear of the figure.
    static func renderInsightsStatRow(scheme: ColorScheme, directory: URL) async {
        let sidePadding = (Theme.Space.xxl + 8) * 2
        let widths: [(String, CGFloat)] = [
            ("narrow", 960 - AssistantPane.sidebarWidth - sidePadding),
            ("wide", 1_320 - AssistantPane.sidebarWidth - sidePadding),
        ]
        for (name, width) in widths {
            let row = InsightsStatRow(
                wordsValue: "123,456", savedValue: "1,240 min",
                savedFootnote: "Since you started · at your typing speed of 120 wpm",
                measureTitle: "Measure again", measure: {}
            ) {
                StatCard(value: "57%", label: "used without edits",
                         footnote: "14 of 33 used without edits · only measured dictations count")
            }
            await capture(
                row.padding(20), name: "insights-stat-row-\(name)", scheme: scheme,
                size: CGSize(width: width + 40, height: 220), directory: directory, fixedSize: true)
        }
    }
}
