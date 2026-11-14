import MurmurCore
import SwiftUI

/// The answer card's file rows: a winner with Open and Show in Finder, or up to five files to pick
/// from. A row shows the name, the folder and the date; the full path is its tooltip and the
/// source line under a single result. The rows never show file contents.
struct FileResultsRows: View {
    let content: FileResultsContent
    let onReveal: (Int) -> Void
    let onOpen: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !content.text.isEmpty {
                Text(content.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(content.rows) { row in
                    FileRowView(row: row, isSingle: content.isSingle, onReveal: { onReveal(row.id) }, onOpen: { onOpen(row.id) })
                }
            }
            if let only = content.rows.first, content.isSingle {
                HStack(spacing: 5) {
                    Circle().fill(Theme.pillWorking).frame(width: 5, height: 5)
                    Text("Found at \(only.shortFolder)/\(only.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
                .help(only.path)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Theme.pillWorking).frame(width: 5, height: 5)
                    Text("Files on this Mac · click one to show it in Finder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct FileRowView: View {
    let row: FileRow
    let isSingle: Bool
    let onReveal: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onReveal) {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: Self.symbol(for: row.kinds))
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.pillWorking)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text([row.shortFolder, row.dateLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .help(row.path)
            .accessibilityLabel("\(row.name), \(row.shortFolder)\(row.dateLabel.map { ", \($0)" } ?? ""). Show in Finder")
            if isSingle {
                Button("Open", action: onOpen).buttonStyle(PillButtonStyle()).help("Open \(row.name)")
            } else {
                Button("Open", action: onOpen).buttonStyle(GhostPillButtonStyle()).help("Open \(row.name)")
            }
        }
        .padding(.vertical, 3)
    }

    static func symbol(for kinds: Set<FileKind>) -> String {
        if kinds.contains(.pdf) { return "doc.richtext" }
        if kinds.contains(.presentation) { return "play.rectangle" }
        if kinds.contains(.spreadsheet) { return "tablecells" }
        if kinds.contains(.image) { return "photo" }
        if kinds.contains(.folder) { return "folder" }
        if kinds.contains(.document) { return "doc.text" }
        return "doc"
    }
}
