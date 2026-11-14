import Foundation
import MurmurCore

/// What the answer card shows for files found on this Mac: a line of text, then one row per file
/// (one for a clear winner, up to five to choose from). Each row carries its real path: that
/// path is the citation, and what Show in Finder and Open act on.
struct FileResultsContent: Equatable {
    var text: String
    var rows: [FileRow]

    var isSingle: Bool { rows.count == 1 }

    /// The rows as `FilePick` sees them, in the order shown.
    var pickRows: [FilePickRow] {
        rows.map { FilePickRow(name: $0.name, kinds: $0.kinds, modified: $0.modified, folder: $0.folderPath) }
    }

    var accessibilityText: String {
        let lines = rows.enumerated().map { index, row in
            "\(index + 1). \(row.name), \(row.shortFolder)\(row.dateLabel.map { ", \($0)" } ?? "")"
        }
        return ([text] + lines).joined(separator: ". ")
    }
}

struct FileRow: Equatable, Identifiable {
    let id: Int
    let path: String
    let name: String
    let folderPath: String
    /// "~/Documents/Jobs": the folder, home shortened, as the card shows it.
    let shortFolder: String
    /// "Mar 3" (this year) or "Mar 3, 2024"; nil when the index had no date.
    let dateLabel: String?
    let kinds: Set<FileKind>
    let modified: Date?

    /// "~/Documents/Jobs" for a folder under home; the full path otherwise.
    static func abbreviate(_ folder: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? String(home.dropLast()) : home
        if folder == prefix { return "~" }
        if folder.hasPrefix(prefix + "/") { return "~" + folder.dropFirst(prefix.count) }
        return folder
    }

    static func label(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d, y")
        return formatter.string(from: date)
    }
}

extension FileRow {
    init(id: Int, candidate: FileCandidate, home: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.init(
            id: id, path: candidate.path, name: candidate.displayName, folderPath: candidate.folderPath,
            shortFolder: Self.abbreviate(candidate.folderPath, home: home),
            dateLabel: candidate.modified.map { Self.label($0, now: now, calendar: calendar, locale: locale) },
            kinds: candidate.kinds, modified: candidate.modified)
    }
}
