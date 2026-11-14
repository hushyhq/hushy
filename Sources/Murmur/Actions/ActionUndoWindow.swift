import Foundation

/// How long a voice action can be taken back. One number for every place that has to agree: the
/// done chip's lifetime (it carries the Undo button), the moment History stops offering Undo for
/// the record (`VoiceActionsController.scheduleUndoExpiry`) and any copy that says it out loud.
/// Before this the chip cleared at 6 s while the record's Undo ran to 8 s, and onboarding said six.
enum ActionUndoWindow {
    static let seconds = 8

    static var interval: TimeInterval { TimeInterval(seconds) }
    static var duration: Duration { .seconds(seconds) }
}
