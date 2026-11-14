import AppKit
import Foundation
import MurmurCore

/// What the file actions do to the Mac: Show in Finder and Open, the only two effects of a file
/// request. Behind a protocol so a test can run the flow without touching Finder.
@MainActor
protocol FileLaunching {
    func exists(_ path: String) -> Bool
    func reveal(_ path: String)
    func open(_ path: String) -> Bool
}

@MainActor
struct WorkspaceFileLauncher: FileLaunching {
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ path: String) -> Bool { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
}

/// The pieces a file request runs on, swappable in tests and snapshots. The controller holds none
/// of this state itself.
@MainActor
enum FileServices {
    static var home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static var engine = FileFindEngine(finder: SpotlightFileFinder(), home: home)
    static var extractor = FileQueryExtractor()
    static var launcher: any FileLaunching = WorkspaceFileLauncher()
}
