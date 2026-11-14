import MurmurCore
import SwiftUI

/// Settings → Privacy & data → "Open Memory…": the sheet with nothing in it, with entries of
/// every kind, paused, with a long note closed and opened out, and with a handful and a long
/// list of the person's edits; then the edit sheet for a word and for a note, and the Privacy
/// rows as they would read in a build that keeps those edits (a proposal, not final wording). Every state is a plain value over invented entries, so no memory folder
/// is read or written and the flag is not touched. `HUSHY_SNAPSHOT_ONLY=memory-pane-` renders
/// just these.
extension Snapshots {
    static func renderMemoryPane(scheme: ColorScheme, directory: URL) async {
        for (name, pane) in MemorySnapshotFixtures.states() {
            await capture(
                pane, name: "memory-pane-\(name)", scheme: scheme,
                size: CGSize(width: MemoryPaneContent.width, height: 120), directory: directory)
        }
        for (name, entry) in MemorySnapshotFixtures.edits() {
            await capture(
                MemoryEntryEditorContent(entry: .constant(entry)), name: "memory-pane-edit-\(name)", scheme: scheme,
                size: CGSize(width: MemoryEntryEditorContent.width, height: 120), directory: directory)
        }
        await capture(
            MemorySnapshotFixtures.privacyRows, name: "memory-pane-privacy-wording", scheme: scheme,
            size: CGSize(width: 780, height: 120), directory: directory)
    }
}

@MainActor
enum MemorySnapshotFixtures {
    /// Every captured state of the sheet, by the name after `memory-pane-`.
    static func states() -> [(String, MemoryPaneContent)] {
        [
            ("empty", pane([])), ("filled", pane(entries)), ("paused", pane(entries, isPaused: true)),
            ("long-profile", pane(longProfile)), ("long-profile-open", pane(longProfile, opensLongNotes: true)),
            ("edits", pane(entries + pairs)), ("edits-long", pane(entries + manyPairs)),
            ("edits-open", pane(Array(manyPairs.prefix(12)), opensAllEdits: true)),
        ]
    }

    /// The edit sheet's two common shapes, by the name after `memory-pane-edit-`.
    static func edits() -> [(String, MemoryEntry)] {
        [("word", entries[2]), ("note", longProfile[0])]
    }

    private static func pane(_ entries: [MemoryEntry], isPaused: Bool = false, opensLongNotes: Bool = false,
                             opensAllEdits: Bool = false) -> MemoryPaneContent {
        MemoryPaneContent(
            entries: entries, isPaused: isPaused, folder: "/Users/you/Library/Application Support/Hushy/Memory",
            appName: { appNames[$0] ?? $0 }, opensLongNotes: opensLongNotes, opensAllEdits: opensAllEdits)
    }

    /// The shorter "Learn from my edits" line the founder is choosing against the one in use.
    static let shorterWording = "To write more like you, Hushy keeps what it wrote and what you changed it to, on this Mac, until you delete it in Memory. It keeps only the part of your dictation you changed, and never reads password fields, password managers or code editors."

    /// "Learn from my edits" in both proposed wordings, labelled, then "Delete learning data".
    static var privacyRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Eyebrow("Option 1 · as built")
                SettingsGroup { LearningSettingsSection(learnFromEdits: .constant(true), keepsChanges: true) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Eyebrow("Option 2 · shorter")
                SettingsGroup { LearningSettingsSection(learnFromEdits: .constant(true), keepsChanges: true, detail: shorterWording) }
            }
            SettingsGroup {
                SettingsRow(title: "Delete learning data", detail: LearningCopy.deleteDetail(keepsChanges: true)) {
                    Button("Delete…") {}.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 780, alignment: .leading)
        .background(Theme.bgBase)
    }

    /// Invented apps: the sheet shows a name, never an icon, so none needs to be installed.
    private static let mail = "app.quillpad.mail"
    private static let notes = "app.lumen.notes"
    private static let appNames = [mail: "Quillpad", notes: "Lumen Notes"]

    /// A profile line, one app's style note, three words and one forgotten word. All invented.
    static let entries: [MemoryEntry] = [
        MemoryEntry(kind: .profile, value: "Short sentences. No exclamation marks. Signs off with a first name only.",
                    createdAt: day(9)),
        MemoryEntry(kind: .style, value: "Lower case, no greeting, one line at a time.", appBundleID: mail, createdAt: day(7)),
        MemoryEntry(kind: .term, value: "Veloria", heardAs: ["valoria", "the loria"], appBundleID: mail, createdAt: day(11)),
        MemoryEntry(kind: .term, value: "Tarrow Ridge", heardAs: ["taro ridge"], appBundleID: notes, createdAt: day(8)),
        MemoryEntry(kind: .term, value: "Nerula", createdAt: day(3)),
        MemoryEntry(kind: .forgotten, value: "Savara", createdAt: day(5)),
    ]

    /// A handful of edits: a misheard name, a trimmed greeting, a changed time, a reworded
    /// opening and a doubled word. All invented.
    static let pairs: [MemoryEntry] = [
        edit("we can meet at Tarrow Rij on Friday", "we can meet at Tavren Ridge on Friday", mail, day(11)),
        edit("Hello team, the draft is ready for review.", "Team, the draft is ready for review", mail, day(10)),
        edit("send it over by end of day tomorrow", "send it over by noon tomorrow", notes, day(9)),
        edit("I think we should probably move the launch", "We should move the launch", mail, day(6)),
        edit("bring the map and the the lantern", "bring the map and the lantern", notes, day(4)),
    ]

    /// Three hundred edits, a few a day back from 11 October.
    static let manyPairs: [MemoryEntry] = (0..<300).map { index in
        let shapes = [
            ("pack \(index + 2) crates for the Veloria run", "pack \(index + 2) boxes for the Veloria run"),
            ("the Nerula notes are attached below.", "The Nerula notes are attached below"),
            ("lets meet at \(index % 11 + 1) by the Tarrow Rij gate", "let's meet at \(index % 11 + 1) by the Tavren Ridge gate"),
        ]
        let shape = shapes[index % shapes.count]
        return edit(shape.0, shape.1, index % 2 == 0 ? mail : notes, day(11).addingTimeInterval(-Double(index) * 21_600))
    }

    private static func edit(_ before: String, _ after: String, _ app: String, _ date: Date) -> MemoryEntry {
        MemoryEntry(kind: .correction, value: "", appBundleID: app, createdAt: date, before: before, after: after)
    }

    /// The same list with a 600-character profile note in place of the short one.
    static let longProfile: [MemoryEntry] = {
        let sentences = [
            "Writes in short sentences and keeps one idea to a line.", "Never uses exclamation marks.",
            "Spells out numbers under ten and uses digits above.", "Prefers plain words to jargon.",
            "Opens messages without a greeting and signs off with a first name only.",
            "Keeps the serial comma.", "Writes dates as day, month, year.", "Keeps product names in their own capitals.",
            "Puts the request first and the reasons after.", "Uses lists when there are more than two items.",
            "Uses no brackets.", "Writes times on the twelve-hour clock with am and pm in lower case.",
            "Leaves a blank line between paragraphs and never indents the first line of one.",
        ]
        let note = String(sentences.joined(separator: " ").prefix(600))
        return [MemoryEntry(kind: .profile, value: note, createdAt: day(9))] + entries.dropFirst()
    }()

    /// Noon on a day of October 2026, so the dates read the same on every Mac.
    private static func day(_ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }
}
