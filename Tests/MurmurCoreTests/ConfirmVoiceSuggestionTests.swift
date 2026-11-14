import Foundation
import Testing
@testable import MurmurCore

/// Confirming an "Is this Dana?" suggestion names the speaker and carries the name into the digest;
/// dismissing and forgetting never do. See the v11 migration's comment for the suggest-never-auto-name contract.
@Suite("Confirming a voice suggestion")
struct ConfirmVoiceSuggestionTests {
    struct Fixture {
        let store: Store
        let noteId: Int64
        let speakerId: Int64
        let otherId: Int64
    }

    private func makeFixture() throws -> Fixture {
        let store = try Store()
        let note = try store.save(Note(
            title: "T", transcript: "t", summary: "- Speaker 1 owns QA\n- Speaker 2 agreed",
            actionItems: ["Speaker 1: Write the test plan", "Speaker 2: Book the room"], status: .ready))
        let noteId = try #require(note.id)
        let speakers = try store.replaceSpeakerSegments(
            noteId: noteId,
            speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1"), NoteSpeaker(noteId: noteId, label: "Speaker 2")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "a")),
                       (1, AlignedSegment(speakerLabel: "S2", start: 1, end: 2, text: "b"))])
        return Fixture(
            store: store, noteId: noteId, speakerId: try #require(speakers[0].id), otherId: try #require(speakers[1].id))
    }

    private func speaker(_ f: Fixture, _ id: Int64) throws -> NoteSpeaker {
        try #require(try f.store.noteSegments(noteId: f.noteId).compactMap(\.speaker).first { $0.id == id })
    }

    private func suggested(_ f: Fixture, name: String = "Dana") throws -> Voice {
        let voice = try f.store.saveVoice(Voice(name: name, encryptedEmbedding: Data([1])))
        try f.store.suggestSpeakerVoice(id: f.speakerId, voiceId: try #require(voice.id), similarity: 0.83)
        return voice
    }

    @Test("confirm links the voice, names the speaker, and rewrites the summary and action items")
    func confirmAppliesNameAndDigest() throws {
        let f = try makeFixture()
        let voice = try suggested(f)

        let linked = try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId)

        #expect(linked == voice.id)
        let speaker = try speaker(f, f.speakerId)
        #expect(speaker.voiceId == voice.id)
        #expect(speaker.displayName == "Dana")
        #expect(speaker.suggestedVoiceId == nil && speaker.suggestedSimilarity == nil)
        let note = try #require(try f.store.note(id: f.noteId))
        #expect(note.summary == "- Dana owns QA\n- Speaker 2 agreed")
        #expect(note.actionItems == ["Dana: Write the test plan", "Speaker 2: Book the room"])
    }

    @Test("a name the user typed earlier is replaced in the digest too")
    func confirmReplacesEarlierName() throws {
        let f = try makeFixture()
        try f.store.renameSpeakerUpdatingDigest(id: f.speakerId, to: "Danny")
        _ = try suggested(f)

        _ = try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId)

        let note = try #require(try f.store.note(id: f.noteId))
        #expect(note.summary == "- Dana owns QA\n- Speaker 2 agreed")
        #expect(try speaker(f, f.speakerId).displayName == "Dana")
    }

    @Test("nothing changes when there is no pending suggestion")
    func confirmWithoutSuggestion() throws {
        let f = try makeFixture()
        #expect(try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId) == nil)
        #expect(try speaker(f, f.speakerId).displayName == nil)
        #expect(try #require(try f.store.note(id: f.noteId)).summary.contains("Speaker 1 owns QA"))
    }

    @Test("a suggestion whose voice is already gone is dropped without naming anyone")
    func confirmWithMissingVoice() throws {
        let f = try makeFixture()
        let voice = try suggested(f)
        try f.store.writer.write { db in
            try db.execute(sql: "DELETE FROM voice WHERE id = ?", arguments: [voice.id])
        }

        #expect(try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId) == nil)
        let speaker = try speaker(f, f.speakerId)
        #expect(speaker.displayName == nil && speaker.voiceId == nil && speaker.suggestedVoiceId == nil)
    }

    @Test("dismissing a suggestion leaves the speaker unnamed and the digest alone")
    func dismissDoesNotName() throws {
        let f = try makeFixture()
        _ = try suggested(f)
        try f.store.dismissSpeakerVoiceSuggestion(id: f.speakerId)
        let speaker = try speaker(f, f.speakerId)
        #expect(speaker.displayName == nil && speaker.voiceId == nil && speaker.suggestedVoiceId == nil)
        #expect(try #require(try f.store.note(id: f.noteId)).summary.contains("Speaker 1 owns QA"))
    }

    // MARK: forgetting

    @Test("forgetting a voice keeps the names already given in old notes")
    func forgetKeepsNames() throws {
        let f = try makeFixture()
        _ = try suggested(f)
        let voiceId = try #require(try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId))

        try f.store.deleteVoice(id: voiceId)

        let speaker = try speaker(f, f.speakerId)
        #expect(speaker.displayName == "Dana")
        #expect(speaker.voiceId == nil)
        #expect(try #require(try f.store.note(id: f.noteId)).summary == "- Dana owns QA\n- Speaker 2 agreed")
    }

    @Test("forgetting a voice also withdraws pending suggestions that pointed at it")
    func forgetClearsPendingSuggestions() throws {
        let f = try makeFixture()
        let voice = try suggested(f)

        try f.store.deleteVoice(id: try #require(voice.id))

        let speaker = try speaker(f, f.speakerId)
        #expect(speaker.suggestedVoiceId == nil && speaker.suggestedSimilarity == nil)
    }

    @Test("forgetting every voice keeps names and clears links and pending suggestions")
    func forgetAll() throws {
        let f = try makeFixture()
        _ = try suggested(f)
        _ = try f.store.confirmSpeakerVoiceSuggestionApplyingName(id: f.speakerId)
        let other = try f.store.saveVoice(Voice(name: "Sam", encryptedEmbedding: Data([2])))
        try f.store.suggestSpeakerVoice(id: f.otherId, voiceId: try #require(other.id), similarity: 0.8)

        try f.store.deleteAllVoices()

        #expect(try f.store.voices().isEmpty)
        let named = try speaker(f, f.speakerId)
        #expect(named.displayName == "Dana" && named.voiceId == nil)
        let pending = try speaker(f, f.otherId)
        #expect(pending.suggestedVoiceId == nil && pending.displayName == nil)
    }
}
