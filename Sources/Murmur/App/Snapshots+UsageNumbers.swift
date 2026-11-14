import MurmurCore
import SwiftUI

/// Task 104 scenes: the "Share usage numbers" switch on and off, and the "See what's sent" sheet
/// with a day's sample numbers, with nothing recorded yet, and with sharing off. Everything is
/// pinned: no event is recorded, no file is written and no network is touched.
extension Snapshots {
    static func renderUsageNumbers(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let original = model.settings.shareUsageNumbers
        for (name, isOn) in [("on", true), ("off", false)] {
            model.settings.shareUsageNumbers = isOn
            await capture(
                SettingsGroup { UsageNumbersSettingsSection(isOn: .constant(isOn)) }.padding(Theme.Space.xl).environment(model),
                name: "usage-numbers-settings-\(name)", scheme: scheme, size: CGSize(width: 640, height: 130),
                directory: directory, fixedSize: true)
        }
        model.settings.shareUsageNumbers = original
        for (name, isOn) in [("on", true), ("off", false)] {
            await capture(
                UsageNumbersNotice(isOn: .constant(isOn)).padding(Theme.Space.xl).environment(model),
                name: "usage-numbers-notice-\(name)", scheme: scheme, size: CGSize(width: 640, height: 190),
                directory: directory, fixedSize: true)
        }
        let sample = UsageNumbersDisclosureView.Phase.sections(sampleSections())
        let phases: [(String, UsageNumbersDisclosureView.Phase, Bool, Bool, CGFloat)] = [
            ("sheet", sample, false, false, 520), ("sheet-sending", sample, true, false, 480),
            ("sheet-details", sample, false, true, 2_300),
            ("sheet-empty", .empty, false, false, 520), ("sheet-off", .off, false, false, 520),
        ]
        for (name, phase, configured, expanded, height) in phases {
            await capture(
                UsageNumbersDisclosureView(phase: phase, isUploadConfigured: configured, startsExpanded: expanded),
                name: "usage-numbers-\(name)", scheme: scheme, size: CGSize(width: 520, height: height),
                directory: directory, fixedSize: true)
        }
    }

    /// A plausible day, built through the same builder and disclosure the app uses.
    private static func sampleSections() -> [MetricsDisclosure.Section] {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_791_028_800)   // 2026-10-03 12:00 UTC
        func dictation(
            _ result: DictationMetricInput.Result, words: Int, release: Int?, backend: EffectiveCleanupBackend = .apple
        ) -> MetricEvent? {
            let input = DictationMetricInput(
                result: result, modelOutcome: .used, backend: backend, cleanupLevel: .clean, mode: nil, wordCount: words,
                audioSeconds: 6.4, speechMilliseconds: 280, cleanupMilliseconds: 640, releaseToDeliveryMilliseconds: release)
            return (try? input.event()).map(MetricEvent.dictation)
        }
        var events = [(0..<9).compactMap { _ in dictation(.pasted, words: 24, release: 930) },
                      [dictation(.copied, words: 11, release: nil)].compactMap { $0 },
                      [dictation(.pasted, words: 8, release: 610, backend: .rules)].compactMap { $0 }].flatMap { $0 }
        events += [.voiceAction(VoiceActionMetricEvent(outcome: .succeeded, failure: nil)),
                   .voiceAction(VoiceActionMetricEvent(outcome: .failed, failure: .permissionDenied)),
                   .meeting(MeetingMetricEvent(outcome: .started, minutesRecorded: nil)),
                   .meeting(MeetingMetricEvent(outcome: .completed, minutesRecorded: 38)),
                   .funnel(.onboardingStarted), .funnel(.microphoneGranted), .funnel(.firstDictation)]
        guard let environment = try? MetricsEnvironment(chipClass: .appleM4OrLater, memoryBand: .upTo32GB, macOSMajor: 27),
              let first = try? MetricsDay(year: 2026, month: 9, day: 12),
              let batch = try? DailyMetricsBuilder(calendar: calendar).close(
                  records: events.compactMap { (try? MetricEventRecord(occurredAt: day, calendar: calendar, appBuild: 412, event: $0)) },
                  environment: environment, now: day.addingTimeInterval(86_400),
                  retention: MetricsRetentionInput(firstRunDay: first, activeDays: [first])).closedBatches.first
        else { return [] }
        return MetricsDisclosure.sections(for: batch, isPreview: true)
    }
}
