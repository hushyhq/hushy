# Resources

- `Info.plist` — bundle metadata and usage strings (`NSMicrophoneUsageDescription`,
  `NSAppleEventsUsageDescription`). `__VERSION__`/`__BUILD__` are filled in by `build-app.sh`
  from `VERSION` and the git commit count.
- `Murmur.entitlements` — audio input, Apple Events, and Calendars (`personal-information.calendars`
  for hardened-runtime builds; reminders has no such key and is gated by TCC alone). The app is intentionally **not sandboxed**: the
  global event tap and paste-into-any-app require Accessibility, which the App Sandbox forbids, so
  distribution is direct download (not the Mac App Store).
