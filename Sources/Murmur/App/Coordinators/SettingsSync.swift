import AppKit
import Foundation
import MurmurCore
import Observation
import os

/// The single path from AppSettings to running services. Any screen can change a setting
/// (Settings, menu bar, onboarding) and it takes effect immediately, everywhere.
@MainActor
final class SettingsSync {
    private let settings: AppSettings
    private let hotkeys: HotkeyMonitor
    private let sounds: Sounds
    private let pill: PillModel
    private let store: Store
    private var lastRetention: Int?? = .none
    private var lastTextRetention: Int?? = .none
    /// Retention also runs periodically, so a menu-bar app left open still expires old data.
    private var retentionTimer: Timer?
    private var lastLanguage: AppSettings.SpeechLanguageMode?
    /// Loads the speech model for a changed language setting (wired by AppModel).
    var onLanguageChange: ((AppSettings.SpeechLanguageMode) -> Void)?
    private let log = Logger(subsystem: "app.hushy", category: "settings")

    init(settings: AppSettings, hotkeys: HotkeyMonitor, sounds: Sounds, pill: PillModel, store: Store) {
        self.settings = settings
        self.hotkeys = hotkeys
        self.sounds = sounds
        self.pill = pill
        self.store = store
    }

    func start() {
        lastLanguage = settings.speechLanguageMode
        apply()
        applyRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyRetention() }
        }
        track()
    }

    private func track() {
        withObservationTracking {
            _ = (settings.triggerKey, settings.actionTrigger, settings.restyleShortcut, settings.soundsEnabled, settings.showIdlePill,
                 settings.hideIdlePillDuringVideoOrFullScreen, settings.audioRetentionDays, settings.textRetentionDays,
                 settings.appearance, settings.speechLanguageMode, settings.keepDictationsOnClipboard)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply()
                if self.lastRetention != .some(self.settings.audioRetentionDays) || self.lastTextRetention != .some(self.settings.textRetentionDays) { self.applyRetention() }
                if let last = self.lastLanguage, last != self.settings.speechLanguageMode {
                    self.onLanguageChange?(self.settings.speechLanguageMode)
                }
                self.lastLanguage = self.settings.speechLanguageMode
                self.track()
            }
        }
    }

    private func apply() {
        hotkeys.trigger = settings.triggerKey
        hotkeys.actionTrigger = settings.effectiveActionTrigger
        hotkeys.restyleShortcut = FeatureFlags.restyleSelection ? settings.restyleShortcut : .off
        sounds.isEnabled = settings.soundsEnabled
        pill.showWhenIdle = settings.showIdlePill
        pill.hideIdleDuringVideoOrFullScreen = settings.hideIdlePillDuringVideoOrFullScreen
        pill.triggerGlyph = settings.triggerKey.glyph
        pill.actionKeyCap = settings.effectiveActionTrigger.keyCap
        Self.applyClipboard(keep: settings.keepDictationsOnClipboard, to: TextInserter.shared)
        let appearance: NSAppearance? = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        guard NSApp.appearance?.name != appearance?.name else { return }
        // Crossfade every window instead of snapping between themes.
        for window in NSApp.windows where window.isVisible {
            guard let layer = window.contentView?.superview?.layer ?? window.contentView?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.35
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "appearance")
        }
        NSApp.appearance = appearance
    }

    /// "Keep dictations on the clipboard" → the paster every dictation goes through.
    static func applyClipboard(keep: Bool, to paster: ClipboardPaster) {
        paster.keepsPastedText = keep
    }

    /// Deletes audio older than the retention setting (and expired cancelled items).
    private func applyRetention() {
        let days = settings.audioRetentionDays
        let textDays = settings.textRetentionDays
        lastRetention = .some(days)
        lastTextRetention = .some(textDays)
        let log = self.log
        Task.detached(priority: .background) { [store] in
            do {
                AudioFiles.remove(paths: try store.applyRetention(audioDays: days, textDays: textDays))
            } catch {
                log.error("retention sweep failed: \(error.localizedDescription)")
            }
        }
    }
}
