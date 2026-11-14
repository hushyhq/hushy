import Foundation

/// Plain-language names for the fixed vocabularies. Every switch is exhaustive on purpose: adding
/// a case to any vocabulary will not compile until its sentence is written here, so the
/// disclosure can never silently omit something that is sent.
public protocol MetricsDisclosureLabel { var disclosureLabel: String { get } }

extension DictationFeedback.Delivery: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .succeeded: "pasted"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .copied: "copied instead of pasted"
        case .heldSecure: "held back (password field)"
        case .noField: "no field to paste into"
        }
    }
}

extension DictationFeedback.EditCoverage: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .observed: "checked"
        case .secure: "secure field"
        case .unknownSecurity: "field type unknown"
        case .fieldUnreadable: "field unreadable"
        case .fieldCleared: "field cleared"
        case .insufficientSignal: "no clear signal"
        case .notAttempted: "not attempted"
        }
    }
}

extension DictationFeedback.FallbackReason: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .disabled: "turned off"
        case .emptyInput: "empty input"
        case .modelUnavailable: "model unavailable"
        case .modelRejected: "model output rejected"
        case .modelTimedOut: "model timed out"
        case .systemBusy: "system busy"
        case .thermalPressure: "Mac running hot"
        case .other: "other"
        }
    }
}

extension CleanupLevel: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .verbatim: "verbatim"
        case .clean: "clean"
        case .polished: "polished"
        }
    }
}

extension MetricsModeKind: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .none: "no mode"
        case .standard: "Default"
        case .email: "Email"
        case .message: "Message"
        case .note: "Note"
        case .bulletPoints: "Bullet points"
        case .custom: "custom (name never sent)"
        }
    }
}

extension MetricsTone: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .refined: "Refined"
        case .professional: "Professional"
        case .casual: "Casual"
        case .prompt: "Prompt"
        case .asSpoken: "As spoken"
        }
    }
}

extension MetricsAppKind: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .aiPrompts: "AI prompts"
        case .email: "Email"
        case .workMessages: "Work messages"
        case .personalMessages: "Personal messages"
        case .documents: "Documents"
        case .code: "Code"
        case .other: "Other"
        }
    }
}

extension MetricsEditVerdict: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .kept: "kept as typed"
        case .edited: "edited"
        case .unknown: "not checked"
        case .fieldCleared: "field cleared"
        }
    }
}

extension MetricsEditSize: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .none: "no edit"
        case .words1to2: "1–2 words"
        case .words3to10: "3–10 words"
        case .wordsMore: "more than 10 words"
        }
    }
}

extension MetricsModelState: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .cold: "model needed loading"
        case .warm: "model already loaded"
        }
    }
}

extension VoiceActionFailureCategory: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .permissionDenied: "permission denied"
        case .notFound: "target not found"
        case .ambiguousTarget: "several matches"
        case .backendFailed: "the app or system failed"
        case .needsInput: "needed more input"
        case .modelUnavailable: "model unavailable"
        case .timedOut: "timed out"
        case .other: "other"
        }
    }
}

extension FunnelStep: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .onboardingStarted: "Onboarding started"
        case .speechDownloadStarted: "Speech model download started"
        case .speechDownloadFinished: "Speech model download finished"
        case .modelReady: "Model ready"
        case .microphoneGranted: "Microphone allowed"
        case .accessibilityGranted: "Accessibility allowed"
        case .firstDictation: "First dictation"
        case .onboardingCompleted: "Onboarding completed"
        }
    }
}

extension MetricsEnvironment.ChipClass: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .appleM1: "Apple M1 class"
        case .appleM2: "Apple M2 class"
        case .appleM3: "Apple M3 class"
        case .appleM4OrLater: "Apple M4 class or newer"
        case .intel: "Intel"
        case .unknown: "unknown chip"
        }
    }
}

extension MetricsEnvironment.MemoryBand: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .upTo8GB: "up to 8 GB memory"
        case .upTo16GB: "9–16 GB memory"
        case .upTo32GB: "17–32 GB memory"
        case .upTo64GB: "33–64 GB memory"
        case .over64GB: "over 64 GB memory"
        case .unknown: "unknown memory"
        }
    }
}

extension MetricsRetention.FirstRunBand: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .day0: "the same day"
        case .days1to6: "1 to 6 days"
        case .days7to29: "1 to 4 weeks"
        case .days30to89: "1 to 3 months"
        case .days90plus: "3 months or more"
        }
    }
}

extension DictationFeedback.CleanupModelProfile: MetricsDisclosureLabel {
    public var disclosureLabel: String {
        switch self {
        case .appleSystem: "Apple's built-in cleanup"
        case .rules: "simple rules"
        case .localFineTuned: "on-device model (tuned)"
        case .localUntuned: "on-device model (not tuned)"
        case .unavailable: "no model available"
        }
    }
}
