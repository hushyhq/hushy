import MurmurCore
import SwiftUI

/// The live readiness both the sidebar's row (`SidebarReadinessRow`) and Home's dictation card
/// (`HomeDictationHero`) show: one computation (`DictationReadinessStatus.compute`, unit-tested)
/// and one set of fixes, so the two surfaces always name the same blocker and do the same thing
/// about it. The card replaced Home's old three-row readiness strip.
extension AppModel {
    /// The first thing standing between the person and a dictation, or `.ready`.
    /// `forcingKeyConflict` is snapshot-only: `--snapshots` can't control the real machine's
    /// Globe-key and Dictation settings (see `EnvironmentValues.snapshotDictateWarning`).
    func dictationReadiness(forcingKeyConflict: Bool = false) -> DictationReadinessStatus {
        DictationReadinessStatus.compute(
            modelState: modelStatus.state,
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            triggerKey: settings.triggerKey,
            fnCaptureActive: hotkeys.isFnCaptureActive,
            globeKeyConflicts: forcingKeyConflict
                || (settings.triggerKey == .fn && Permissions.globeKeyAction.conflicts),
            macDictationClashes: Permissions.macDictationClashes(with: settings.triggerKey),
            download: modelStatus.download,
            meteredPause: downloads.needsMeteredConsent || downloads.waitingForUnmetered)
    }

    /// Runs a readiness state's fix: ask for the microphone or Accessibility, open Keyboard
    /// settings, retry the speech model, or approve a download on a metered network. It never
    /// starts a dictation.
    func runReadinessFix(_ fix: DictationReadinessStatus.Fix?) {
        switch fix {
        case .requestMicrophone: Task { await permissions.requestMicrophone() }
        case .requestAccessibility:
            permissions.requestAccessibility()
            installHotkeys()
        case .openKeyboardSettings: Permissions.openKeyboardSettings()
        case .retryModel: retryModelDownload()
        case .approveMeteredDownload: downloads.approveMeteredDownload()
        case nil: break
        }
    }
}
