import Foundation
import MurmurCore

/// A dictation that produced no text, as the pill says it (`PillState.failed`).
///
/// It stays until the person dismisses it, acts on it or starts another dictation: a failure that
/// shows for two seconds is one nobody saw. The one exception is `missedWords` (`isBrief`): the
/// microphone worked and nothing needs fixing, so its line leaves by itself. It never blocks the next dictation (the dictation
/// key replaces it), takes no key from the app in front, and never carries dictated words.
enum DictationFailure: Equatable, Sendable {
    /// Recognition threw. `recordingKept` when the audio is still in memory behind the row's
    /// Try again (`PillModel.present(failure:retry:)`): never on disk for this, and let go when
    /// the row goes.
    case transcription(recordingKept: Bool)
    /// Recognition ran and returned no words.
    case noWords
    /// A real attempt that the microphone heard, with no words in the end: one short line that
    /// leaves by itself (`isBrief`). `heardSpeech` when the speech gate let it through.
    /// See `EmptyDictationTriage`.
    case missedWords(heardSpeech: Bool)
    /// Words were heard, and cleanup left nothing to write.
    case nothingToWrite
    /// The microphone delivered sound, and none of it was speech.
    case heardNothing
    /// The microphone delivered exact silence: the capture path, not a quiet room.
    case micSilent
    /// The key was released while a Bluetooth headset's call link was still coming up, or a moment
    /// after: the recording holds no sound, or a fragment of a word (`HeadsetLinkHold`). Nothing
    /// went to the recogniser. Not a fault of the headset or of the person, so no error tone.
    case headsetConnecting
    /// The recording's samples could not be what a microphone heard (`AudioReadFault`): a faulty
    /// read of the device. Nothing went to the recogniser. `mic` is the device as macOS names it,
    /// when known.
    case micUnreadable(mic: String?, next: UnreadableNext)
    /// Recording never began: the microphone, its permission or the speech model. The message is
    /// the app's own line for that reason.
    case didNotStart(String)
    /// A note finished without a complete transcript. The same persistent row as a dictation
    /// that produced no text: it used to flash "Note incomplete" and vanish.
    case noteIncomplete
    /// The dictation produced no text and the microphone delivered hardly any sound, or none
    /// (`InputHearing.heardLittle`). The row names the microphone, and offers the Mac's own when
    /// that is another one (`QuietMic`). It takes the place of the four failures above it.
    case quietMic(QuietMic)
    /// The person took that offer: Hushy now records from the named microphone. Not a failure, but
    /// it is the same row one tap later, and like the row it stays until ✕ or the next dictation.
    case micSwitched(to: String)
    /// The person took the other offer: the Microphone setting is back on Automatic.
    case usingAutomatic
    /// The microphone taken from the quiet row's offer delivered hardly any sound on the very
    /// next recording, so Hushy put the Microphone setting back where it was (`backTo` nil is
    /// Automatic) and says so: an offer never leaves the person on a microphone that does not work.
    case pickUndone(mic: String, backTo: String?)

    /// What happened, in a few words.
    var message: String {
        switch self {
        case .transcription: "Couldn't transcribe"
        case .noWords: "Didn't catch any words"
        case .missedWords(let heardSpeech): heardSpeech ? "Didn't catch any words" : "Didn't hear any words"
        case .nothingToWrite: "Couldn't make text from that"
        case .heardNothing: "Didn't hear anything"
        case .micSilent: "Mic sent no audio"
        case .headsetConnecting: "Headset was still connecting"
        case .micUnreadable(let mic, _): "Couldn't read \(mic.map(QuietMic.rowName) ?? "the microphone")"
        case .didNotStart(let message): message
        case .noteIncomplete: Self.noteIncompleteMessage
        case .quietMic(let mic): mic.message
        case .micSwitched(let name): "Using \(QuietMic.rowName(name))"
        case .usingAutomatic: "Using \(MicrophoneResolution.automaticTitle)"
        case .pickUndone(let mic, _): "\(QuietMic.rowName(mic)) sent no sound"
        }
    }

    /// What to do next, after a "·" on the same line. Nil when the message says it.
    var detail: String? {
        switch self {
        case .transcription(recordingKept: true): "your recording is still here"
        case .transcription(recordingKept: false): "recording not kept, dictate again"
        case .nothingToWrite: "dictate again"
        case .noWords: "dictate again, a little louder"
        case .missedWords: nil
        case .heardNothing: "check your mic, then dictate again"
        case .micSilent: "pick another input in Settings"
        case .headsetConnecting: "give it a second, then speak"
        case .micUnreadable(_, .dictateAgain): "dictate again"
        case .micUnreadable(_, .offerAutomatic): nil
        case .micUnreadable(_, .putBack): "setting put back"
        case .didNotStart, .noteIncomplete: nil
        case .quietMic(let mic): mic.detail
        case .micSwitched, .usingAutomatic: "dictate again"
        // The earlier pick is not named: with two device names the row would not fit the pill.
        case .pickUndone(_, let backTo): backTo == nil ? "back to \(MicrophoneResolution.automaticTitle)" : "back to your pick"
        }
    }

    /// The other microphone the row offers in one tap, by its device name; nil for every row
    /// that offers none.
    var micOffer: String? {
        if case .quietMic(let mic) = self { return mic.betterInput }
        return nil
    }

    /// The row offers the way back to Automatic in one tap: a picked microphone that delivered
    /// hardly any sound while the Mac's sound input is another one.
    var offersAutomatic: Bool {
        switch self {
        case .quietMic(let mic): mic.offersAutomatic
        case .micUnreadable(_, .offerAutomatic): true
        default: false
        }
    }

    /// The row is for a headset that delivered only exact zeros.
    var isHeadsetSilence: Bool {
        if case .quietMic(let mic) = self { return mic.headsetSilence }
        return false
    }

    /// One short line that leaves by itself after `EmptyDictationTriage.briefLifetime`: no ✕, and a
    /// quiet dot instead of the red one, since nothing is broken.
    var isBrief: Bool {
        if case .missedWords = self { return true }
        return false
    }

    /// The row reports something that went right (a tick, not the red dot).
    var isGoodNews: Bool {
        switch self {
        case .micSwitched, .usingAutomatic: true
        default: false
        }
    }

    /// The row as one line of words: "Didn't catch any words · dictate again, a little louder".
    var line: String {
        [message, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// The row offers Try again: only a failed transcription whose audio is still held. Running
    /// the same audio again after "no words" or "nothing heard" would give the same nothing.
    var canRetry: Bool { self == .transcription(recordingKept: true) }

    /// The line a note shows when it finishes incomplete. Persistent (`PillState.failed`), not a
    /// timed error.
    static let noteIncompleteMessage = "Note incomplete"

    /// The two messages that used to flash on the error row and disappear. They are the persistent
    /// failure row instead, so a person who looks away still sees them.
    static func persistent(message: String) -> DictationFailure? {
        switch message {
        case PillModel.microphoneFailedMessage: .didNotStart(message)
        case noteIncompleteMessage: .noteIncomplete
        default: nil
        }
    }

    static let retryTitle = "Try again"
    static let retryHelp = "Runs it again from the audio Hushy is still holding. It is held for ten minutes at most; dismissing this or dictating again lets it go sooner."
    /// How long a failed dictation's audio is held in memory for Try again. The row has no timer,
    /// so without this a long recording could sit in memory for as long as nobody looks. When it
    /// is up the row stays and changes to its not-kept wording (`PillModel.dropKeptAudio`).
    static let keptAudioLifetime: Duration = .seconds(600)

    /// What VoiceOver reads for the row: the same words, as sentences.
    var accessibilityText: String {
        let said = [message, detail].compactMap { $0 }.map(Self.sentence).joined(separator: " ")
        if case .quietMic(let mic) = self, mic.headsetSilence, let offer = micOffer {
            return "\(said) \(QuietMic.silenceAdvice) Or press \(QuietMic.switchTitle) to record from \(QuietMic.rowName(offer))."
        }
        if let offer = micOffer { return "\(said) Press \(QuietMic.switchTitle) to record from \(QuietMic.rowName(offer))." }
        if offersAutomatic { return "\(said) Press \(QuietMic.automaticTitle) to use Automatic microphone selection." }
        return canRetry ? "\(said) Press \(Self.retryTitle) to run it again." : said
    }

    /// "dictate again" → "Dictate again."; a line that already ends in punctuation keeps it.
    private static func sentence(_ words: String) -> String {
        let capitalised = words.prefix(1).uppercased() + words.dropFirst()
        guard let last = capitalised.last, !".…!?".contains(last) else { return capitalised }
        return capitalised + "."
    }

    /// The failures that sounded the error tone before they stayed: something broke, as opposed
    /// to nothing having been heard.
    var playsErrorSound: Bool {
        switch self {
        case .transcription, .micSilent, .didNotStart, .noteIncomplete, .micUnreadable: true
        case .noWords, .missedWords, .nothingToWrite, .heardNothing, .headsetConnecting, .micSwitched, .usingAutomatic, .pickUndone: false
        // As the failure it stands in for: the tone for exact silence from the capture path, none
        // for a recording with nothing heard in it (a key pressed by accident is not an error).
        case .quietMic(let mic): mic.soundsError
        }
    }
}

/// What the row for a faulty read offers next.
enum UnreadableNext: Equatable, Sendable {
    /// Nothing to change: the microphone is the Mac's sound input.
    case dictateAgain
    /// The microphone was picked in Hushy and the Mac's sound input is another: one tap back.
    case offerAutomatic
    /// The microphone had just been taken from the row's offer: Hushy put the setting back.
    case putBack
}

/// What the quiet-microphone row says: which microphone delivered hardly any sound, and the
/// Mac's own microphone when that is a different one the person can switch to in one tap.
///
/// The words name the microphone and never the person: nothing here says they spoke too softly.
/// Device names are shown as macOS shows them, since that is the name the person knows it by.
struct QuietMic: Equatable, Sendable {
    /// The microphone the recording used, as macOS names it.
    var micName: String
    /// It delivered no sound at all, as opposed to hardly any.
    var isSilent: Bool
    /// The Mac's built-in microphone, by device name, when the recording used another one.
    var betterInput: String?
    /// The failure this row stands in for sounded the error tone (`DictationFailure.micSilent`).
    var soundsError = false
    /// A Bluetooth headset that delivered nothing but exact zeros for longer than its link takes
    /// to come up: muted on the headset, or held by another device. The row says that instead of
    /// the general "no sound".
    var headsetSilence = false
    /// The recording used a microphone picked in Hushy while the Mac's sound input is another
    /// one, and there is no better input to offer: the row offers Automatic instead.
    var offersAutomatic = false
    /// What to try with a headset that sent only silence.
    static let silenceAdvice = "Check it is not muted, or reconnect it."
    /// The button that puts the Microphone setting back on Automatic.
    static let automaticTitle = "Use \(MicrophoneResolution.automaticTitle)"
    static let automaticHelp = "Hushy uses Automatic microphone selection. Change it any time in Settings → General → Microphone."
    /// The button that switches to `betterInput`.
    static let switchTitle = "Use Mac mic"
    static func switchHelp(_ name: String) -> String {
        "Hushy records from \(name) from now on. Change it any time in Settings → General → Microphone."
    }

    /// The longest device name a row draws; a longer one is cut in the middle, where a model
    /// number usually is, so both the owner's name and the kind of device stay readable.
    static let rowNameLimit = 26

    static func rowName(_ name: String) -> String {
        let clean = InputDeviceInfo.cleanName(name)
        guard clean.count > rowNameLimit else { return clean }
        let head = (rowNameLimit - 1) / 2 + (rowNameLimit - 1) % 2
        return clean.prefix(head).trimmingCharacters(in: .whitespaces) + "…"
            + clean.suffix(rowNameLimit - 1 - head).trimmingCharacters(in: .whitespaces)
    }

    private var amount: String { isSilent ? "No sound" : "Hardly any sound" }

    /// With a switch on offer the row is the microphone's name and the button. With none, the
    /// name is the thing to check.
    var message: String {
        if headsetSilence { return "\(Self.rowName(micName)) sent only silence" }
        return hasOffer ? "\(amount) from \(Self.rowName(micName))" : "\(amount) came in"
    }

    var detail: String? {
        // With a button the row has no room for advice; VoiceOver and the button's help say it.
        if headsetSilence { return hasOffer ? nil : "reconnect it" }
        return hasOffer ? nil : "check \(Self.rowName(micName))"
    }

    private var hasOffer: Bool { betterInput != nil || offersAutomatic }

    /// Which row a dictation that produced no text shows. `base` is the failure as it would have
    /// been said; it stands unless the recording held hardly any sound and the microphone is known.
    /// A better input is the Mac's built-in microphone (`builtInInput`, its device name, when the
    /// Mac has one), and only when the recording used another.
    ///
    /// `pickedApartFromSystemInput`: the recording used a microphone picked in Hushy and the Mac's
    /// sound input is another device. With no better input to offer, the row then offers the way
    /// back to Automatic, so a pick that delivers nothing is never a dead end.
    static func failure(_ base: DictationFailure, hearing: InputHearing, device: InputDeviceInfo?,
                        builtInInput: String?, pickedApartFromSystemInput: Bool = false) -> DictationFailure {
        guard hearing.heardLittle, let device else { return base }
        let better = device.transport == .builtIn || builtInInput == device.name ? nil : builtInInput
        return .quietMic(QuietMic(micName: device.name, isSilent: hearing.heardNothing, betterInput: better,
                                  soundsError: base.playsErrorSound,
                                  // Nearly all of it exact zeros: a link that never carried the microphone.
                                  headsetSilence: device.transport == .bluetooth && hearing.heardNothing
                                      && hearing.deadSeconds >= hearing.seconds * 0.9,
                                  offersAutomatic: better == nil && pickedApartFromSystemInput))
    }
}

extension PillState {
    /// A dictation failure is showing.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
