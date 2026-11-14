import AppKit

/// Everything on a pasteboard at one moment: every item, every type, in the order the owner
/// declared them (receivers prefer the first type they accept, so order is part of the clipboard).
/// Types whose data cannot be read (a promise that never resolves) are counted, not hidden.
struct ClipboardSnapshot: Sendable {
    struct Entry: Sendable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    let items: [[Entry]]
    /// Types that were declared but whose data came back nil.
    let droppedTypeCount: Int

    var itemCount: Int { items.count }
    var typeCount: Int { items.reduce(0) { $0 + $1.count } }
    var byteCount: Int { items.reduce(0) { total, entries in total + entries.reduce(0) { $0 + $1.data.count } } }

    @MainActor
    static func capture(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
        var dropped = 0
        var items: [[Entry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [Entry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append(Entry(type: type, data: data))
                } else {
                    dropped += 1
                }
            }
            if !entries.isEmpty { items.append(entries) }
        }
        return ClipboardSnapshot(items: items, droppedTypeCount: dropped)
    }

    /// Puts this snapshot back as the whole clipboard. False when the pasteboard refused it
    /// (twice) or kept fewer items than were written.
    @MainActor
    func restore(to pasteboard: NSPasteboard) -> Bool {
        for _ in 0..<2 {
            pasteboard.clearContents()
            if items.isEmpty { return true }
            let written = items.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for entry in entries { item.setData(entry.data, forType: entry.type) }
                return item
            }
            if pasteboard.writeObjects(written), pasteboard.pasteboardItems?.count == items.count { return true }
        }
        return false
    }
}

/// What one paste did to the clipboard, as the single `clipboard` log line. Fixed words and numbers
/// only: never any clipboard or dictation text.
struct ClipboardPasteRecord: Sendable {
    enum Origin: String, Sendable { case snapshotted, reused }
    enum Ending: String, Sendable {
        case restored
        case keptBySetting = "kept-by-setting"
        case keptUnconfirmed = "kept reason=unconfirmed"
        case skippedClipboardChanged = "skipped-clipboard-changed"
        case failedToWrite = "failed-to-write"
        case handedToNextPaste = "handed-to-next-paste"
        case replacedByCopy = "replaced-by-copy"
        case notStaged = "not-staged"
    }

    let origin: Origin
    let items: Int
    let types: Int
    let bytes: Int
    let dropped: Int

    init(origin: Origin, saved: ClipboardSnapshot) {
        self.origin = origin
        items = saved.itemCount
        types = saved.typeCount
        bytes = saved.byteCount
        dropped = saved.droppedTypeCount
    }

    func line(_ ending: Ending) -> String {
        "paste original=\(origin.rawValue) items=\(items) types=\(types) bytes=\(bytes) dropped=\(dropped) restore=\(ending.rawValue)"
    }
}
