import MurmurCore
import SwiftUI

/// Review set for "find my file" on the pill (`pill-files-<state>`): one file shown in Finder, a
/// list of several to pick from, a single file that only mentions the words, nothing found, and
/// Spotlight not searching. Invented file names and an invented home folder; nothing is read from
/// the disk.
extension Snapshots {
    static func renderPillFiles(scheme: ColorScheme, directory: URL) async {
        let levels = [0.3, 0.5, 0.8, 0.4, 1.0, 0.6, 0.9, 0.35, 0.55]
        for (name, state) in fileStates() {
            let pill = PillModel()
            pill.state = state
            pill.setLevels(levels)
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: "pill-files-\(name)", scheme: scheme, size: CGSize(width: 560, height: 440),
                          directory: directory, fixedSize: true)
        }
    }

    private static func fileStates() -> [(String, PillState)] {
        let home = "/Users/ada"
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        func day(_ year: Int, _ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))! }
        func row(_ id: Int, _ path: String, _ modified: Date, _ kinds: Set<FileKind>) -> FileRow {
            FileRow(id: id, candidate: FileCandidate(path: home + "/" + path, modified: modified, kinds: kinds),
                    home: home, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        }
        let resume = row(0, "Documents/Jobs/Resume.pdf", day(2026, 9, 20), [.pdf, .document])
        let invoices = [
            row(0, "Documents/Finance/Invoice acme march.pdf", day(2026, 3, 2), [.pdf, .document]),
            row(1, "Documents/Finance/Invoice dana april.pdf", day(2026, 4, 2), [.pdf, .document]),
            row(2, "Downloads/Invoice 2024 globex.pdf", day(2024, 11, 10), [.pdf, .document]),
            row(3, "Desktop/Invoice template.docx", day(2025, 1, 14), [.document]),
        ]
        let mention = row(0, "Documents/Notes/Onboarding checklist.docx", day(2026, 6, 2), [.document])
        func card(_ question: String, _ phase: AnswerCardState.Phase) -> PillState {
            .answer(AnswerCardState(question: question, phase: phase))
        }
        return [
            ("one", card("can you find and fetch my resume",
                         .files(.init(text: FileCardText.showing, rows: [resume])))),
            ("several", card("show me my invoices", .files(.init(text: FileCardText.severalMatches, rows: invoices)))),
            ("mentions", card("find the doc about kafka", .files(.init(text: FileCardText.mentionsOne, rows: [mention])))),
            ("none", card("find my visa pdf", .failure(.init(message: FileCardText.nothing(in: nil), suggestion: nil)))),
            ("none-folder", card("find my resume on my desktop",
                                 .failure(.init(message: FileCardText.nothing(in: .desktop), suggestion: nil)))),
            ("unavailable", card("find my resume",
                                 .failure(.init(message: FileCardText.unavailable(.indexOff), suggestion: nil)))),
            ("searching", { var state = AnswerCardState(question: "find my resume", phase: .thinking)
                state.thinkingLabel = FileCardText.searching
                return PillState.answer(state) }()),
        ]
    }
}
