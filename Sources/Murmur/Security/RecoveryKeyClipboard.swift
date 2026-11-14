import AppKit

@MainActor
protocol RecoveryKeyPasteboard {
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    @discardableResult func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: RecoveryKeyPasteboard {}

@MainActor
enum RecoveryKeyClipboard {
    static func copy(_ key: String, to board: any RecoveryKeyPasteboard = NSPasteboard.general) {
        // Universal Clipboard must not carry a recovery key to another device.
        board.prepareForNewContents(with: .currentHostOnly)
        board.writeObjects([ClipboardPaster.transientItem(key)])
    }
}
