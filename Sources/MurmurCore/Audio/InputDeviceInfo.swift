import Foundation

/// How a microphone reaches the Mac. It decides what its audio can be: a Bluetooth headset in its
/// call profile is mono at 8 to 24 kHz and can deliver nothing while the link comes up, which the
/// Mac's own microphone never does.
///
/// Built from Core Audio's transport code as a plain number, so `MurmurCore` keeps no Core Audio
/// dependency (as `SystemAudioTypes` does).
public enum InputTransport: String, Sendable, Equatable, CaseIterable {
    case builtIn = "built-in"
    case bluetooth
    case usb
    /// A software device: a loopback driver, a virtual cable.
    case virtual
    /// Several devices joined into one. Voice processing makes a private one of these.
    case aggregate
    case other

    /// `code` is `kAudioDevicePropertyTransportType`: a four-character code such as 'bltn'.
    public init(coreAudioTransportType code: UInt32) {
        switch code {
        case Self.fourCC("bltn"): self = .builtIn
        case Self.fourCC("blue"), Self.fourCC("blea"): self = .bluetooth
        case Self.fourCC("usb "): self = .usb
        case Self.fourCC("virt"): self = .virtual
        case Self.fourCC("grup"): self = .aggregate
        default: self = .other
        }
    }

    /// 'bltn' as Core Audio stores it: four ASCII bytes, first character highest.
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// The microphone one recording used: its name, how it is connected, and the format it opened
/// with. Four facts and nothing about what was said.
public struct InputDeviceInfo: Sendable, Equatable {
    public let name: String
    public let transport: InputTransport
    public let sampleRate: Double
    public let channels: Int

    public init(name: String, transport: InputTransport, sampleRate: Double, channels: Int) {
        self.name = Self.cleanName(name)
        self.transport = transport
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The capture log's line for a recording: `"AirPods Pro" · bluetooth · 16000 Hz · 1 ch`.
    public var logSummary: String {
        Self.logSummary(name: name, transport: transport, sampleRate: sampleRate, channels: channels)
    }

    /// The same line when the device could not be named: `unknown device · 48000 Hz · 1 ch`.
    public static func logSummary(name: String?, transport: InputTransport?, sampleRate: Double, channels: Int) -> String {
        let format = "\(Int(sampleRate.rounded())) Hz · \(channels) ch"
        guard let name, let transport else { return "unknown device · \(format)" }
        return "\"\(cleanName(name))\" · \(transport.rawValue) · \(format)"
    }

    /// The longest device name kept. Longer ones are cut at the end.
    public static let nameLimit = 64

    /// A device name fit for one log line or one row: no control characters or line breaks, no
    /// runs of spaces, at most `nameLimit` characters. The name comes from a driver, so it is
    /// treated as outside data.
    public static func cleanName(_ name: String) -> String {
        var printable = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let isBreak = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            printable.append(isBreak ? " " : scalar)
        }
        let words = String(printable).split(separator: " ", omittingEmptySubsequences: true)
        return String(words.joined(separator: " ").prefix(nameLimit))
    }
}
