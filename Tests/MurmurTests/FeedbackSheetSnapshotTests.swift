import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Murmur

/// Renders the feedback sheet for review, light and dark, only when asked:
/// `HUSHY_FEEDBACK_SNAPSHOTS=<dir> swift test --filter FeedbackSheetSnapshotTests`.
@MainActor
struct FeedbackSheetSnapshotTests {
    @Test func renderFeedbackSheet() async throws {
        guard let path = ProcessInfo.processInfo.environment["HUSHY_FEEDBACK_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let states: [(String, FeedbackSheetContent)] = [
            ("feedback-sheet", content(message: "The shortcut did not start dictation in Slack after I woke the Mac.")),
            ("feedback-sheet-empty", content(message: "")),
            ("feedback-sheet-preparing", content(message: "Pasting went to the wrong window.", isPreparing: true)),
            ("feedback-sheet-error", content(message: "Pasting went to the wrong window.", error: FeedbackCopy.mailFailed)),
            ("feedback-window", content(message: "Pasting went to the wrong window.", showsTitle: false)),
        ]
        for (name, view) in states {
            for scheme in [ColorScheme.light, .dark] {
                await Snapshots.capture(view, name: name, scheme: scheme, size: CGSize(width: FeedbackSheetContent.width, height: 1),
                                        directory: directory)
            }
        }
    }

    private func content(message: String, showsTitle: Bool = true, isPreparing: Bool = false,
                         error: String? = nil) -> FeedbackSheetContent {
        FeedbackSheetContent(message: .constant(message), attachDiagnostics: .constant(true),
                             showsTitle: showsTitle, isPreparing: isPreparing, error: error)
    }
}
