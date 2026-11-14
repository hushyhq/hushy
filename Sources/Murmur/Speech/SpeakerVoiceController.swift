import Foundation
import MurmurCore
import os

/// Drives "Remember <name>'s voice" and the confirm-time voice update from the transcript. It holds only
/// the consent state per speaker; the learning itself is `SpeakerVoiceMemory`, and nothing is computed or
/// stored until `confirm` (the user pressed Remember). Logs say what happened, never whose voice.
@MainActor
@Observable
final class SpeakerVoiceController {
    private let store: Store
    private let encryption: EncryptionController
    @ObservationIgnored private let diarizer = SpeakerDiarizer()
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "voices")
    /// Where each speaker is in the consent steps; absent means idle.
    private var flows: [Int64: RememberVoiceFlow] = [:]

    init(store: Store, encryption: EncryptionController) {
        self.store = store
        self.encryption = encryption
    }

    func flow(for speakerId: Int64) -> RememberVoiceFlow { flows[speakerId] ?? .idle }

    /// Which speakers' chip menus offer the action, read once per transcript render by the view.
    func availability(of speakers: [NoteSpeaker], noteId: Int64) -> [Int64: RememberVoiceAvailability] {
        guard let note = try? store.note(id: noteId) else { return [:] }
        let memory = makeMemory()
        let entitled = Entitlements.has(.voiceSignatures)
        var result: [Int64: RememberVoiceAvailability] = [:]
        for speaker in speakers {
            guard let id = speaker.id else { continue }
            result[id] = memory.availability(of: speaker, in: speakers, note: note, entitled: entitled)
        }
        return result
    }

    /// "Remember <name>'s voice" was chosen: show the consent line. Nothing is stored yet.
    func request(speakerId: Int64) { flows[speakerId] = flow(for: speakerId).requested() }

    /// "Not now" on the consent line.
    func cancel(speakerId: Int64) { flows[speakerId] = flow(for: speakerId).cancelled() }

    /// "Remember" on the consent line: the only path that computes and saves an embedding.
    func confirm(speakerId: Int64) async {
        guard Entitlements.has(.voiceSignatures) else { return }
        let working = flow(for: speakerId).confirmed()
        guard working == .working else { return }
        flows[speakerId] = working
        let outcome = await makeMemory().remember(speakerId: speakerId)
        flows[speakerId] = working.finished(outcome)
        if case .declined = outcome { log.notice("remember voice declined") }
    }

    /// After a suggestion was confirmed: fold this note's audio into the saved voice, quietly.
    func reinforce(speakerId: Int64, voiceId: Int64) async {
        guard Entitlements.has(.voiceSignatures) else { return }
        let outcome = await makeMemory().reinforce(speakerId: speakerId, voiceId: voiceId)
        if outcome == .skipped { log.notice("voice update skipped") }
    }

    private func makeMemory() -> SpeakerVoiceMemory {
        SpeakerVoiceMemory(
            store: store, signatures: encryption.voiceSignatureStore,
            embedder: DiarizerVoiceEmbedder(diarizer: diarizer, key: encryption.currentKey, store: store))
    }
}
