import Foundation
import GRDB

/// How the people in a meeting were told it was recorded, kept with the meeting so the person can
/// show it later. Hushy records only after a click; this records the second half of consent:
/// telling the others. One row per note, replaced when the person changes it.
public struct MeetingConsent: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting_consent"

    public enum Method: String, Codable, Sendable, CaseIterable {
        /// The notice was copied to paste into the meeting's chat.
        case chatMessage
        /// The person said it out loud ("I'm taking notes with Hushy, on my Mac only").
        case saidAloud
        /// Everyone already knew (a call with oneself, a team rule).
        case alreadyKnew
    }

    public var noteId: Int64
    public var method: Method
    public var at: Date

    public init(noteId: Int64, method: Method, at: Date = Date()) {
        self.noteId = noteId
        self.method = method
        self.at = at
    }

    /// The line the person pastes into the meeting chat, or reads out. It says only what is true:
    /// recorded on this Mac, nothing sent to Hushy, nobody trains on it.
    public static func notice(userName: String) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "I'm" : "\(name) here: I'm"
        return "\(who) recording this call for my notes with Hushy. It stays on my Mac; nothing is sent to Hushy or used to train AI. Say if you'd rather I didn't."
    }

    /// The short line said aloud at the start.
    public static let spokenLine = "Quick note: I'm recording this for my own notes. It stays on my Mac and isn't used to train anything. OK with everyone?"

    public var summary: String {
        let time = at.formatted(date: .omitted, time: .shortened)
        return switch method {
        case .chatMessage: "Told everyone in the chat at \(time)"
        case .saidAloud: "Said it out loud at \(time)"
        case .alreadyKnew: "Everyone knew it was recorded"
        }
    }
}

extension Store {
    public func recordConsent(_ consent: MeetingConsent) throws {
        try writer.write { db in try consent.save(db) }
    }

    public func consent(forNote noteId: Int64) throws -> MeetingConsent? {
        try writer.read { db in try MeetingConsent.fetchOne(db, key: noteId) }
    }
}
