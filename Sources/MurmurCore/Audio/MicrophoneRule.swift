import Foundation

/// One input the Mac has: the name macOS gives it and how it is connected.
public struct MicrophoneCandidate: Sendable, Equatable {
    public let name: String
    public let transport: InputTransport
    public let isUsable: Bool

    public init(name: String, transport: InputTransport, isUsable: Bool = true) {
        self.name = name
        self.transport = transport
        self.isUsable = isUsable
    }
}

/// What the Mac has to record from at this moment, as plain values so the rule below can be
/// tested without any hardware.
public struct MicrophoneInventory: Sendable, Equatable {
    /// Every input device, the system default included.
    public var inputs: [MicrophoneCandidate]
    /// The input macOS records from by default (System Settings → Sound → Input).
    public var systemDefault: MicrophoneCandidate?

    public init(inputs: [MicrophoneCandidate], systemDefault: MicrophoneCandidate?) {
        self.inputs = inputs
        self.systemDefault = systemDefault
    }

    public var builtIn: MicrophoneCandidate? { inputs.first { $0.transport == .builtIn && $0.isUsable } }
    /// A Bluetooth headset's microphone, if one is connected: the system default when that is
    /// Bluetooth, otherwise the first Bluetooth input.
    public var headset: MicrophoneCandidate? {
        if let systemDefault, systemDefault.transport == .bluetooth { return systemDefault }
        return inputs.first { $0.transport == .bluetooth }
    }
}

/// Which microphone a recording opens, and why.
///
/// The Microphone setting is either a device the person picked or "Automatic" (nothing picked).
/// A pick always wins. Automatic uses the built-in input when the system input is Bluetooth,
/// followed by a usable wired input and finally the headset. A flag keeps the former rule.
///
/// This decides only what Hushy opens. It never changes the system's default input.
public struct MicrophoneResolution: Sendable, Equatable {
    public enum Rule: String, Sendable, Equatable {
        /// The person picked this device and it is connected.
        case picked
        /// The person picked a device that is not connected: the system default, as before.
        case pickedMissing
        /// Automatic: the system default, including under the legacy flag.
        case followsSystem
        case builtInOverBluetooth
        case wiredFallback
        case headsetFallback
    }

    public let rule: Rule
    /// The device to open, by name; nil opens the system default input.
    public let deviceName: String?
    /// The microphone the recording will use, for display; nil when the Mac has no input.
    public let using: MicrophoneCandidate?
    /// The connected headset whose microphone a pick of the Mac's own microphone leaves closed.
    public let headsetLeftAlone: MicrophoneCandidate?
    /// The picked device that is not connected.
    public let missing: String?

    public init(rule: Rule, deviceName: String?, using: MicrophoneCandidate?, headsetLeftAlone: MicrophoneCandidate? = nil,
                missing: String? = nil) {
        self.rule = rule
        self.deviceName = deviceName
        self.using = using
        self.headsetLeftAlone = headsetLeftAlone
        self.missing = missing
    }

    public static func resolve(picked: String?, inventory: MicrophoneInventory,
                               followsSystemInput: Bool = false) -> MicrophoneResolution {
        let system = inventory.systemDefault
        guard let picked else {
            guard !followsSystemInput, system?.transport == .bluetooth else {
                return MicrophoneResolution(rule: .followsSystem, deviceName: nil, using: system)
            }
            if let builtIn = inventory.builtIn {
                return MicrophoneResolution(rule: .builtInOverBluetooth, deviceName: builtIn.name, using: builtIn)
            }
            if let wired = inventory.inputs.first(where: { $0.isUsable && $0.transport != .bluetooth
                && $0.transport != .virtual && $0.transport != .aggregate }) {
                return MicrophoneResolution(rule: .wiredFallback, deviceName: wired.name, using: wired)
            }
            return MicrophoneResolution(rule: .headsetFallback, deviceName: nil, using: system)
        }
        guard let device = inventory.inputs.first(where: { $0.name == picked }) else {
            return MicrophoneResolution(rule: .pickedMissing, deviceName: nil, using: system, missing: picked)
        }
        return MicrophoneResolution(
            rule: .picked, deviceName: device.name, using: device,
            headsetLeftAlone: device.transport == .builtIn ? inventory.headset : nil)
    }

    // MARK: Words

    public static let automaticTitle = "Automatic"

    /// The Automatic entry in the Microphone picker, when this is what Automatic resolves to:
    /// "Automatic · MacBook Pro Microphone". Only the word when the Mac has no input to name.
    public var automaticLabel: String {
        guard let using else { return Self.automaticTitle }
        return "\(Self.automaticTitle) · \(InputDeviceInfo.cleanName(using.name))"
    }

    /// The line under the Microphone setting: what Hushy records from and why. One or two lines
    /// across the row, because the picker beside it already names the microphone.
    public var settingNote: String {
        let name = using.map { InputDeviceInfo.cleanName($0.name) } ?? "the Mac's sound input"
        switch rule {
        case .picked:
            guard let headset = headsetLeftAlone else { return "Always uses this microphone." }
            return "\(InputDeviceInfo.cleanName(headset.name)) keeps its music quality and noise cancelling. "
                + "Speak up: this microphone is further from you, and room noise gets in."
        case .pickedMissing:
            return "\(InputDeviceInfo.cleanName(missing ?? "That microphone")) is not connected, so Hushy uses \(name)."
        case .followsSystem:
            return using == nil ? "No microphone found." : "Uses the microphone your Mac is set to use."
        case .builtInOverBluetooth:
            return "Automatic uses the Mac's microphone when a Bluetooth headset is connected, so the start of what you say is not lost and your music keeps its quality."
        case .wiredFallback:
            return "The Mac's microphone is unavailable, so Automatic uses a connected wired microphone."
        case .headsetFallback:
            return "The Mac's microphone is unavailable, so Automatic uses the headset's microphone."
        }
    }

    /// The capture log's word for how the device was chosen. No names.
    public var logWord: String {
        switch rule {
        case .picked: "picked"
        case .pickedMissing: "picked device missing: system input"
        case .followsSystem: "auto: system input"
        case .builtInOverBluetooth: "auto: built-in, system input is bluetooth"
        case .wiredFallback: "auto: wired fallback, no built-in"
        case .headsetFallback: "auto: headset, nothing else"
        }
    }
}
