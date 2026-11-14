# Murmur (the macOS app)

SwiftUI + AppKit app. Built into `build/Murmur.app` by `scripts/build-app.sh`.

| Folder | Contents |
|---|---|
| `App/` | `MurmurApp` (scenes, menus, menu bar extra), `AppModel` (composition root + navigation), `AppSettings` (UserDefaults-backed preferences), `OnboardingFunnelRecorder` (local-only first-run timings, gate 11), `Snapshots` (`--snapshots` renderer), `Coordinators/` (`Library` live data + actions, `Library+Learning` learned-items UI API, `SettingsSync` settings → services, `PillCoordinator` pill window, `DownloadCoordinator` model downloads: start at launch, metered/offline gate, backoff, optional-asset queue incl. offer/accept/pause/remove, `CleanupModelController` the "Cleanup model" setting: backend switch without restart, local-model download/verify/delete, memory pressure, diagnostics; `LocalBackendFactory+MLX` the only HushyModelsMLX import) |
| `Dictation/` | `DictationController` — the push-to-talk state machine and hot path; `LatencyBreakdown` |
| `Audio/` | `AudioCapture` (AVAudioEngine, voice processing, device selection, levels), `WAVWriter` |
| `Speech/` | `SpeechEngine` (FluidAudio Parakeet Ultra, download/verify/load/warm-up, pause), `SpeechModelStatus` (passive throughput, smoothed ETA), `SpeechModelIntegrity` (checksums against Hugging Face's listing) |
| `Input/` | `HotkeyMonitor` (event tap on its own thread, `EventTapThread`, timed from event stamps, `EventClock`: fn/⌥/⌘ hold, double-tap, fn+Space, Esc, ⌃⌘V paste-last, ⌃⌘C copy-last), `TextInserter` + `ClipboardPaster` (paste, clipboard restore) + `FocusTarget` (key-down target, a late field adopted at paste time, the landing read, browser titles) + `AXFocusReader` (live AX focus for `TargetGuard`, bounded reads), `EditWatcher` (edit-free verdict + learn-from-corrections capture; `EditWatcherLive`: one extra look when Return goes down in the watched app) |
| `Notes/` | `NoteRecorder` — chunked progressive transcription and summaries |
| `Pill/` | `PillModel` (state + levels), `PillView` (all states, resting wave, no-field card), `PillPanel` (non-activating floating window), `PillMotion` (every duration, curve and spring the pill uses, read by role), `PillWait` (the wait between release and paste as a pure function: fold, labels, progress line), `Preview/` (`--pill-preview`: the real pill played from a script of invented states, `scripts/pill-preview.sh`) |
| `System/` | `Permissions`, `Sounds` (synthesized cues), `MCPInstaller`, `AppleNotesExporter`, `UpdateChecker` (Sparkle 2, inert until `Info.plist` carries a real feed/key — see docs/guide/RELEASE.md); `Uninstall/` — `LiveUninstall` (this copy's folders, what makes a test run, the Keychain sweep and the system calls behind each step) and `UninstallFlow` (review, speech-model choice, export offer, confirmation, report, ⌘Q) for Settings → About → "Uninstall Hushy…"; the stop steps are in `App/AppModel+Uninstall.swift` |
| `UI/` | `Theme` (design tokens), `Components/` (cards, buttons, banners, history timeline, cleanup picker), `Screens/` (one file per page + onboarding + menu bar) |

Conventions:
- Views read data from `model.library` and settings from `model.settings`; they never write to
  services directly. Settings reach services through `SettingsSync` only.
- Anything slow (disk, database, summaries) happens after the paste.
- Check UI changes with `.build/debug/Murmur --snapshots <dir>` in light and dark.
