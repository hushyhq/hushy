import Foundation

/// Hardware facts used to choose local model tiers. `MachineProfile` remains the source-compatible name.
public typealias HardwareProfile = MachineProfile

/// The Mac a model has to fit: installed RAM and chip class. Decode speed is set by memory
/// bandwidth, which follows the chip class (base ≈ 68–120 GB/s, Pro/Max ≥ 150 GB/s), not by RAM
/// — so both matter (INFERENCE-OPTIMIZATION §4).
public struct MachineProfile: Equatable, Sendable {
    public enum ChipClass: String, Equatable, Sendable {
        case base, pro, max, ultra, unknown

        /// Pro, Max and Ultra chips have the bandwidth the 2B needs to stay "free".
        public var isHighBandwidth: Bool { self == .pro || self == .max || self == .ultra }
    }

    public let physicalMemoryGB: Int
    public let chip: ChipClass
    /// "Apple M4 Pro" — for logs and Settings, never sent anywhere.
    public let chipName: String
    public let isLowPowerModeEnabled: Bool

    public init(physicalMemoryGB: Int, chip: ChipClass, chipName: String = "", isLowPowerModeEnabled: Bool = false) {
        self.physicalMemoryGB = physicalMemoryGB
        self.chip = chip
        self.chipName = chipName
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// This Mac, from `hw.memsize` and `machdep.cpu.brand_string`.
    public static func current() -> MachineProfile {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Int((Double(bytes) / 1_073_741_824).rounded())
        let name = sysctlString("machdep.cpu.brand_string") ?? ""
        return MachineProfile(physicalMemoryGB: gb, chip: chipClass(brand: name), chipName: name,
                              isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// "Apple M2 Max" → `.max`; "Apple M1" → `.base`; Intel or unreadable → `.unknown`.
    public static func chipClass(brand: String) -> ChipClass {
        let words = brand.split(separator: " ").map { $0.lowercased() }
        guard words.contains(where: { $0.hasPrefix("m") && $0.dropFirst().allSatisfy(\.isNumber) && $0.count > 1 }) else {
            return .unknown
        }
        if words.contains("ultra") { return .ultra }
        if words.contains("max") { return .max }
        if words.contains("pro") { return .pro }
        return .base
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The RAM-tier rule (M5, INFERENCE-OPTIMIZATION §4.1, updated 2026-10-27): 8 GB → 0.8B; 16 GB+ → the 2B intent
/// model; 24 GB+ on a Pro/Max/Ultra chip → the 4B intent model. Any other entry is allowed as an override, with a
/// warning that says what it costs on this Mac.
public enum ModelTierPolicy {
    /// The intent cleanup model is the default (founder 2026-10-21): the 2B on every Mac that qualifies, and
    /// since 2026-10-27 the 4B on 24 GB+ Pro/Max Macs ("replace the 2B with the 4B; that's what we cater to").
    public static let intentModelsAreDefault = true

    /// Whether the app delivers the *sealed* twins of the Hushy-hosted intent models (weights as AES-256-GCM chunks that
    /// only Hushy's own process opens) instead of the plain files. This is the last step of the roll-out, after
    /// the sealed files are uploaded, their keys are Worker secrets and the Worker is deployed
    /// (docs/engineering/SEALED-MODELS.md, "Roll-out"). Turning it on moves existing installs over through the normal
    /// handover: the plain model keeps answering while the sealed one downloads and is verified, then it is deleted.
    public static let sealedModelsAreDefault = false

    public static func qualifiesFor2BIntent(_ machine: MachineProfile) -> Bool {
        machine.physicalMemoryGB >= 16 && machine.chip != .unknown
    }

    /// The 4B intent model needs 24 GB and Pro-class bandwidth (M4 Pro: p50 0.40 s, p90 0.87 s, about 3.3 GB resident).
    public static func qualifiesFor4BIntent(_ machine: MachineProfile) -> Bool {
        machine.physicalMemoryGB >= 24 && machine.chip.isHighBandwidth
    }

    /// The default intent model: the 4B on 24 GB+ Pro/Max/Ultra Macs, the 2B on every other Mac that qualifies
    /// (public 300: 4B equal to the 2B; Disfl-QA 272 vs 209; real tones through register lines).
    /// `prefer2B` is the hidden way back to the 2B (`preferIntentCleanup2B`).
    public static func defaultIntentEntry(
        for machine: MachineProfile, prefer2B: Bool = false, sealed: Bool = sealedModelsAreDefault
    ) -> LocalModelEntry? {
        let plain: LocalModelEntry?
        if !prefer2B, qualifiesFor4BIntent(machine) {
            plain = ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B)
        } else {
            plain = qualifiesFor2BIntent(machine) ? ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent) : nil
        }
        return plain.map { ModelRegistry.delivered($0, sealed: sealed) }
    }

    /// The writing models a fresh install on this Mac downloads after the speech model, in order: the 2B alone
    /// on a 16 GB+ Mac, the 2B and then the 4B on a 24 GB+ Pro/Max Mac (the 2B answers while the 4B downloads,
    /// PR 158), none below 16 GB. Onboarding sizes its download line from this; the downloads themselves are
    /// queued by `CleanupModelController`.
    public static func firstRunWritingDownloads(
        for machine: MachineProfile, prefer2B: Bool = false, sealed: Bool = sealedModelsAreDefault
    ) -> [LocalModelEntry] {
        guard intentModelsAreDefault, qualifiesFor2BIntent(machine),
              let plainTwoB = ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent) else { return [] }
        let twoB = ModelRegistry.delivered(plainTwoB, sealed: sealed)
        if !prefer2B, qualifiesFor4BIntent(machine), let fourB = ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B) {
            return [twoB, ModelRegistry.delivered(fourB, sealed: sealed)]
        }
        return [twoB]
    }

    /// The intent model behind the hidden `useIntentCleanup4B` switch: the 4B on 24 GB+ Pro/Max chips, which is
    /// now also the default; the switch stays because it wins over an explicit model choice.
    public static func intentEntry(for machine: MachineProfile, sealed: Bool = sealedModelsAreDefault) -> LocalModelEntry? {
        defaultIntentEntry(for: machine, sealed: sealed)
    }

    /// Whether meeting and note summaries run on the cleanup model that is already loaded. They do when that
    /// model is the 4B (`docs/research/r10d-meeting-score-2026-10-28.md`: owner+task recall 77% against Apple
    /// FM's 52% on the 12-meeting dev set, no refusals). The 2B was never measured on meetings, so a Mac whose
    /// cleanup runs on the 2B (16 GB, or the 4B still downloading), on Apple FM or on rules keeps summarising on
    /// Apple FM. There is no second copy of the 4B for meetings: the same instance answers both.
    public static func meetingUsesCleanupModel(_ backend: EffectiveCleanupBackend) -> Bool {
        if case .local(let id) = backend { return id == ModelRegistry.hushyCleanup4B }
        return false
    }

    public enum Fit: Equatable, Sendable {
        case recommended
        /// Allowed, but not what we'd pick for this Mac; the text says why.
        case override(warning: String)
    }

    /// Below this, a Mac is "8 GB class" (the smallest tier; also the idle-unload tier).
    public static let smallTierMaximumGB = 8

    public static func promotedEntry(for machine: MachineProfile) -> LocalModelEntry? {
        guard machine.chip != .unknown, machine.physicalMemoryGB > smallTierMaximumGB else { return nil }
        return ModelRegistry.entries.first {
            $0.role == .cleanupDefault && $0.minimumMemoryGB <= machine.physicalMemoryGB
        }
    }

    public static func recommendedEntryID(
        for machine: MachineProfile, useIntentModels: Bool = intentModelsAreDefault, prefer2B: Bool = false,
        sealed: Bool = sealedModelsAreDefault
    ) -> String {
        if useIntentModels, let intent = defaultIntentEntry(for: machine, prefer2B: prefer2B, sealed: sealed) { return intent.id }
        if let promoted = promotedEntry(for: machine) { return promoted.id }
        guard machine.physicalMemoryGB > smallTierMaximumGB else { return ModelRegistry.qwen08B4bit }
        return machine.chip.isHighBandwidth ? ModelRegistry.qwen2B6bit : ModelRegistry.qwen08B4bit
    }

    public static func recommended(
        for machine: MachineProfile, useIntentModels: Bool = intentModelsAreDefault, prefer2B: Bool = false,
        sealed: Bool = sealedModelsAreDefault
    ) -> LocalModelEntry {
        ModelRegistry.entry(id: recommendedEntryID(
            for: machine, useIntentModels: useIntentModels, prefer2B: prefer2B, sealed: sealed))
            ?? ModelRegistry.entries[0]
    }

    public static func fit(_ entry: LocalModelEntry, on machine: MachineProfile, prefer2B: Bool = false) -> Fit {
        // A sealed entry is the same model as its plain twin: it fits, and is recommended, exactly as that one does.
        if entry.logicalID == recommendedEntryID(for: machine, prefer2B: prefer2B, sealed: false) { return .recommended }
        if machine.physicalMemoryGB < entry.minimumMemoryGB {
            let gb = Double(entry.residentMegabytes) / 1_000
            return .override(warning: String(
                format: "Uses about %.1f GB of memory while loaded — a lot for a Mac with %d GB. Other apps may slow down.",
                gb, machine.physicalMemoryGB))
        }
        if entry.logicalID == ModelRegistry.hushyCleanup2BIntent, qualifiesFor4BIntent(machine) {
            return .override(warning: "Slightly faster, but less careful than the 4B model recommended for this Mac.")
        }
        if entry.parameterLabel == "2B", !machine.chip.isHighBandwidth {
            return .override(warning: "Slower on this chip: about 0.3–0.6 s per cleanup instead of ~0.2 s.")
        }
        if entry.parameterLabel == "0.8B" {
            return .override(warning: "Faster but less careful than the model recommended for this Mac.")
        }
        return .override(warning: "Not the model we'd pick for this Mac; it should still work.")
    }

    /// Seconds of idle before the model is unloaded: 120 s on ≤ 8 GB Macs, never (session-long)
    /// on bigger ones (M6).
    public static func idleUnloadSeconds(for machine: MachineProfile) -> TimeInterval? {
        machine.physicalMemoryGB <= smallTierMaximumGB ? 120 : nil
    }

    /// One line of RAM/size guidance for Settings: "2.19 GB download · about 1.5 GB of memory while loaded".
    public static func guidance(for entry: LocalModelEntry) -> String {
        let download = ModelDownloadProgress.formatBytes(entry.downloadBytes)
        let resident = Double(entry.residentMegabytes) / 1_000
        let memory = resident < 1 ? "\(entry.residentMegabytes) MB" : String(format: "%.1f GB", resident)
        return "\(download) download · about \(memory) of memory while loaded"
    }
}
