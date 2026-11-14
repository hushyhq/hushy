import Foundation
import GRDB

extension Store {
    public func noteSpeaker(id: Int64) throws -> NoteSpeaker? {
        try writer.read { db in try NoteSpeaker.fetchOne(db, key: id) }
    }

    /// The user confirmed an "Is this Dana?" suggestion: link the voice, clear the suggestion, give the
    /// speaker the voice's name and carry that name into the summary and action items, exactly as a
    /// typed rename does — in one transaction. Returns the linked voice's id, or `nil` when there was
    /// nothing to confirm (no pending suggestion, or its voice was forgotten meanwhile; the stale
    /// suggestion is dropped and nobody is named).
    ///
    /// This is the only path that turns a suggestion into a name, and it runs only on the user's yes.
    @discardableResult
    public func confirmSpeakerVoiceSuggestionApplyingName(id: Int64) throws -> Int64? {
        try writer.write { db in
            guard let speaker = try NoteSpeaker.fetchOne(db, key: id), let voiceId = speaker.suggestedVoiceId else {
                return nil
            }
            guard let voice = try Voice.fetchOne(db, key: voiceId) else {
                try db.execute(
                    sql: "UPDATE note_speaker SET suggestedVoiceId = NULL, suggestedSimilarity = NULL WHERE id = ?",
                    arguments: [id])
                return nil
            }
            let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try db.execute(
                sql: """
                    UPDATE note_speaker
                    SET voiceId = ?, suggestedVoiceId = NULL, suggestedSimilarity = NULL, displayName = ?
                    WHERE id = ?
                    """,
                arguments: [voiceId, name.isEmpty ? nil : name, id])
            let old = [speaker.label] + (speaker.displayName.map { [$0] } ?? [])
            try rewriteDigest(db, noteId: speaker.noteId, from: old, to: name.isEmpty ? speaker.label : name)
            return voiceId
        }
    }
}
