import Foundation
import MurmurCore

/// Which microphone a voice action records from: the Microphone setting through the app's one
/// selector, so an action and a dictation always use the same one.
extension VoiceActionsController {
    /// Points the capture at the microphone a dictation would use now. Opens nothing.
    @discardableResult
    func prepareMicrophone() -> MicrophoneResolution {
        microphones.prepare(audio, picked: pickedMicrophone())
    }
}
