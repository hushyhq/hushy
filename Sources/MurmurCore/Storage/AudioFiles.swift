import Foundation

/// Removes dictation audio from disk. A recording may exist as `x.wav`, as `x.wav.enc`
/// (encryption on; the database still names `x.wav`), or both mid-migration, so every
/// deletion goes through here instead of removing the stored path alone.
public enum AudioFiles {
    private static let sealedSuffix = ".enc"

    public static func remove(_ path: String) {
        let manager = FileManager.default
        try? manager.removeItem(atPath: path)
        try? manager.removeItem(atPath: path + sealedSuffix)
    }

    public static func remove(paths: [String]) {
        for path in paths { remove(path) }
    }

    /// Moves a file to the user's Trash.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The erase-time cleanup. Moves to the Trash every regular file directly in `directory`
    /// whose name is exactly a UUID plus `.wav` or `.wav.enc`, the names Hushy gives its
    /// recordings. Any other name, a subfolder or a link is never touched. A file that cannot be
    /// moved stays. Returns how many moved.
    @discardableResult
    public static func trashLeftovers(in directory: URL, dispose: (URL) throws -> Void = moveToTrash) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        var moved = 0
        for file in files where isHushyRecordingName(file.lastPathComponent) {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if (try? dispose(file)) != nil { moved += 1 }
        }
        return moved
    }

    private static func isHushyRecordingName(_ name: String) -> Bool {
        for suffix in [".wav", ".wav" + sealedSuffix] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }
        return false
    }
}
