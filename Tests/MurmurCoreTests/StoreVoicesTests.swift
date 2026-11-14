import Foundation
import Testing
@testable import MurmurCore

/// Covers the `voice` table (migration "v11-voices") and its interaction with `note_speaker`:
/// CRUD, the "at most one `isYou` row" invariant, suggestion confirm/dismiss, and delete
/// propagation (unlinking `note_speaker.voiceId`/`suggestedVoiceId` without touching segments) —
/// the "rename/merge propagation" tests this task requires, for the voice-signature layer
/// specifically (speaker-level rename/merge is covered by `StoreNoteSpeakersTests`).
@Suite("Store voices")
struct StoreVoicesTests {
    private func makeNote(_ store: Store) throws -> Int64 {
        let note = try store.save(Note(title: "Test note", transcript: "hi", status: .ready))
        return try #require(note.id)
    }

    private func makeSpeaker(_ store: Store, noteId: Int64) throws -> Int64 {
        let inserted = try store.replaceSpeakerSegments(
            noteId: noteId, speakers: [NoteSpeaker(noteId: noteId, label: "Speaker 1")],
            segments: [(0, AlignedSegment(speakerLabel: "S1", start: 0, end: 1, text: "hi"))])
        return try #require(inserted.first?.id)
    }

    @Test("saveVoice inserts and voices() returns it")
    func savesAndFetchesVoice() throws {
        let store = try Store()
        let saved = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1, 2, 3])))
        #expect(saved.id != nil)
        let all = try store.voices()
        #expect(all.count == 1)
        #expect(all.first?.name == "Dana")
    }

    @Test("saving a second isYou voice replaces the first, never leaving two")
    func onlyOneYouVoiceCanExist() throws {
        let store = try Store()
        _ = try store.saveVoice(Voice(name: "You", isYou: true, encryptedEmbedding: Data([1])))
        _ = try store.saveVoice(Voice(name: "You (re-enrolled)", isYou: true, encryptedEmbedding: Data([2])))

        let all = try store.voices()
        #expect(all.count == 1)
        #expect(all.first?.name == "You (re-enrolled)")
        #expect(try store.youVoice()?.name == "You (re-enrolled)")
    }

    @Test("saving a non-you voice alongside an existing you voice keeps both")
    func nonYouVoiceCoexistsWithYouVoice() throws {
        let store = try Store()
        _ = try store.saveVoice(Voice(name: "You", isYou: true, encryptedEmbedding: Data([1])))
        _ = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([2])))
        #expect(try store.voices().count == 2)
    }

    @Test("renameVoice updates the name without touching any linked speaker's displayName")
    func renameVoiceDoesNotTouchSpeakerNames() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.setSpeakerVoice(id: speakerId, voiceId: voice.id)
        try store.renameVoice(id: try #require(voice.id), to: "Danielle")

        #expect(try store.voice(id: try #require(voice.id))?.name == "Danielle")
        let segments = try store.noteSegments(noteId: noteId)
        // The speaker's own displayName (set via renameSpeaker, not renameVoice) is untouched —
        // per docs/research/speaker-labeling.md §2.6, linking/renaming a voice never invents or
        // changes a speaker's own display name.
        #expect(segments.first?.speaker?.displayName == nil)
    }

    @Test("renaming to an empty/whitespace-only string is a no-op")
    func renameVoiceIgnoresEmptyName() throws {
        let store = try Store()
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.renameVoice(id: try #require(voice.id), to: "   ")
        #expect(try store.voice(id: try #require(voice.id))?.name == "Dana")
    }

    @Test("deleteVoice removes the row and unlinks any speaker's voiceId, keeping the segment")
    func deleteVoiceUnlinksSpeakers() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.setSpeakerVoice(id: speakerId, voiceId: voice.id)

        try store.deleteVoice(id: try #require(voice.id))

        #expect(try store.voices().isEmpty)
        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.count == 1, "the transcript segment must survive a voice deletion")
        #expect(segments.first?.speaker?.voiceId == nil)
    }

    @Test("deleteAllVoices clears every voice and unlinks every speaker")
    func deleteAllVoicesUnlinksEverything() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voiceA = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        _ = try store.saveVoice(Voice(name: "Sam", encryptedEmbedding: Data([2])))
        try store.setSpeakerVoice(id: speakerId, voiceId: voiceA.id)

        try store.deleteAllVoices()

        #expect(try store.voices().isEmpty)
        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.first?.speaker?.voiceId == nil)
    }

    @Test("suggestSpeakerVoice only applies to a speaker with no existing voiceId")
    func suggestOnlyAppliesWhenUnlinked() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voiceA = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        let voiceB = try store.saveVoice(Voice(name: "Sam", encryptedEmbedding: Data([2])))
        try store.setSpeakerVoice(id: speakerId, voiceId: voiceA.id)

        // Attempting to suggest a different voice on an already-linked speaker must not overwrite
        // the confirmed link — "never auto-name without a confirmed match" extends to "never
        // silently re-suggest over a confirmed one" too.
        try store.suggestSpeakerVoice(id: speakerId, voiceId: try #require(voiceB.id), similarity: 0.9)

        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.first?.speaker?.voiceId == voiceA.id)
        #expect(segments.first?.speaker?.suggestedVoiceId == nil)
    }

    @Test("confirmSpeakerVoiceSuggestion promotes suggestedVoiceId to voiceId and clears the suggestion")
    func confirmPromotesSuggestion() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.suggestSpeakerVoice(id: speakerId, voiceId: try #require(voice.id), similarity: 0.82)

        try store.confirmSpeakerVoiceSuggestion(id: speakerId)

        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.first?.speaker?.voiceId == voice.id)
        #expect(segments.first?.speaker?.suggestedVoiceId == nil)
        #expect(segments.first?.speaker?.suggestedSimilarity == nil)
    }

    @Test("dismissSpeakerVoiceSuggestion clears the suggestion without linking a voice")
    func dismissClearsWithoutLinking() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.suggestSpeakerVoice(id: speakerId, voiceId: try #require(voice.id), similarity: 0.82)

        try store.dismissSpeakerVoiceSuggestion(id: speakerId)

        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.first?.speaker?.voiceId == nil)
        #expect(segments.first?.speaker?.suggestedVoiceId == nil)
    }

    @Test("setSpeakerVoice(voiceId: nil) unlinks without touching displayName")
    func setSpeakerVoiceNilUnlinks() throws {
        let store = try Store()
        let noteId = try makeNote(store)
        let speakerId = try makeSpeaker(store, noteId: noteId)
        let voice = try store.saveVoice(Voice(name: "Dana", encryptedEmbedding: Data([1])))
        try store.setSpeakerVoice(id: speakerId, voiceId: voice.id)
        try store.renameSpeaker(id: speakerId, to: "Custom Name")

        try store.setSpeakerVoice(id: speakerId, voiceId: nil)

        let segments = try store.noteSegments(noteId: noteId)
        #expect(segments.first?.speaker?.voiceId == nil)
        #expect(segments.first?.speaker?.displayName == "Custom Name")
    }
}
