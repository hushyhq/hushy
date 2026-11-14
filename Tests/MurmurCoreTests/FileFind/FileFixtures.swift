import Foundation
@testable import MurmurCore

/// A made-up home folder and clock for the file-finding tests. No real path is ever read.
enum FileFixtures {
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    /// 2026-10-06 12:00 UTC.
    static let now = date(2026, 10, 6)

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static func file(
        _ relative: String, _ modified: Date?, kinds: Set<FileKind> = [], lastUsed: Date? = nil, folder: Bool = false
    ) -> FileCandidate {
        FileCandidate(path: home.path + "/" + relative, modified: modified, lastUsed: lastUsed, kinds: kinds, isFolder: folder)
    }

    static let pdf: Set<FileKind> = [.pdf, .document]
    static let docx: Set<FileKind> = [.document]
    static let slides: Set<FileKind> = [.presentation]
    static let sheet: Set<FileKind> = [.spreadsheet]
    static let image: Set<FileKind> = [.image]

    static func request(
        _ terms: [String], kind: FileKind = .any, time: FileTimeHint? = nil, location: FileLocation? = nil,
        action: FileAction = .reveal
    ) -> FileRequest {
        FileRequest(query: FileQuery(terms: terms, kind: kind, time: time, location: location)!, action: action)
    }

    /// The time boxes default to an hour: the fake index answers at once (or, when a test gives it a
    /// `delay`, only when the time box or a cancel stops it), so a stalled or busy machine can never
    /// turn an ordinary search into "slow". A test of the time box passes a short `passBox`.
    static func engine(
        _ finder: InMemoryFileFinder, passBox: Duration = .seconds(3600), totalBox: Duration = .seconds(3600)
    ) -> FileFindEngine {
        FileFindEngine(
            finder: finder, home: home, now: { now }, calendar: calendar, passTimeBox: passBox, totalTimeBox: totalBox)
    }

    static func decide(_ utterance: String) -> FileRouting {
        FileRouter.decide(AskRouter.frame(utterance), now: now, calendar: calendar)
    }
}
