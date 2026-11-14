# Never lose a take

The promise: **a dictation that reached Hushy ends in the field, on the clipboard, or in History.** This page
says what keeps the promise today, what was added for it on 2026-11-07, how each part is tested, and what
is left as a design.

## What keeps the promise

| A take that ... | Where the words are | Kept for | Test |
|---|---|---|---|
| is pasted and confirmed | the field | forever in History, per the History setting | `TargetedDeliveryTests` |
| is pasted into an uncertain target and cannot be read back | the clipboard (kept) and History | the History setting | `TargetedDeliveryTests` |
| is pasted into a known field of a native app, without Return, and the second look finds nothing changed | clipboard, card, History (listed as not pasted) | the History setting | `FieldPasteLandingTests`, `FieldWatchTests`, `TextInserterHandoverTests`, `LateLandingControllerTests` |
| is pasted into a known field that is not watched (a browser page, Electron, a paste sent with Return, a field not read at key-down) | the field; if it was lost, History only | the History setting | `PasteMatrixTests` |
| cannot be pasted (focus moved, no field, paste key failed) | clipboard, card, History | the History setting | `TargetedDeliveryTests`, `DeliveryPresentationTests` |
| meets a password field | History only, by design | the History setting | `TargetedDeliveryTests` |
| is cancelled with Esc while speaking | History row "Cancelled", words read from the recording; audio per the audio setting | 24 hours, 20 takes, 1 hour of audio | `CancelledTakeRetentionTests` |
| is cancelled with Esc while the recording is read | the same; the recording is read again after Esc | the same | `LateLandingControllerTests` |
| fails to transcribe | History row "Failed" with the audio when audio is kept, and Try again from memory when it is not | the History and audio settings | `DictationRecoveryControllerTests` |

The settings rule: audio follows "Keep dictation audio" (Don't keep writes no file, for a cancelled take
too), and text follows "Keep history". Nothing here keeps anything those settings would not.

## Added on 2026-11-07

1. **Esc during recognition no longer loses the words.** Before, the recognition ended with the take, so the
   row held only audio (or nothing, with audio off). A fresh task now reads the recording again, as Esc
   while speaking always did.
2. **Recover no longer clears the clipboard.** A cancelled row with audio and no words used to copy an
   empty string. History now offers Retry transcription for it (`DictationRecovery`).
3. **Cancelled takes are bounded in size.** 20 takes and one hour of audio (about 115 MB), newest first, the
   newest always kept. Before, only the 24 hours bounded them.
4. **A lost paste into a known field is caught.** After the pill shows Done, the field is read again. If it
   was readable and unchanged, the row is listed as not pasted, the words go on the clipboard, and the
   "Couldn't confirm the paste" card opens. See the handbook page "When a paste fails". The "before" is
   the read made at key-down, so nothing is read between the end of cleanup and ⌘V. It is made for dictation's key-down target only, not for paste last or the voice-action fallback, which
   paste without a second look. The look runs only
   in an explicit allowlist of Apple text views (`FieldWatch.watchedApps`: TextEdit, Notes and Mail), where a
   lost paste leaves the count unchanged and the person's own Return adds a line instead of sending or
   clearing. Every other app is unwatched: browsers (including every Chromium browser, listed or not),
   Electron, CEF and WebView2 apps, terminals and the agent composers inside them, Messages, Xcode, Pages and
   Word. A denylist of those failed three reviews, each on an app type nobody had listed. It does not run
   after a paste sent with Return either, because a composer that sends and clears itself reads the same
   before and after. The look gives up after two seconds, bounds
   every read of the other app including the guard check, and ends when the next dictation starts. It
   leaves the clipboard alone if the person has copied something since the paste.
5. **The paste matrix** for 30 apps, generated from the delivery code: `PASTE-MATRIX.md`.
6. **The re-read after Esc yields.** It starts only when no dictation is under way and the recogniser lane
   has no other pass running or waiting (`RecogniserLane.whenIdle`), so the next take never queues behind
   it unless the re-read had already started. A take that begins while the re-read waits or runs cancels it
   (`yieldToNewTake`), so it cannot take the gap between that take's live drafts; it asks again once the
   controller is idle and no take is starting. A recogniser that ignores cancellation finishes the read it began.

## Design: pause and resume (not built)

Why not built: it needs a new control on the pill, and the founder approves new copy and interaction. The
work is also not small: capture, the dictation state machine, the hands-free timer and the live cleaning
all change.

- **State.** A recording session gets `.paused`. Esc cancels from it, as today. Resume returns to recording.
- **Capture.** Keep the engine running and drop buffers while paused, so resume has no start-up delay and a
  Bluetooth headset is not reopened. Join the two parts with about 150 ms of silence so the recogniser does
  not glue the last word before the pause to the first after it.
- **Clocks.** The 30-minute hands-free cap counts recorded time only. The live-draft ticks and early
  cleaning stop while paused.
- **Focus.** The target is bound at key-down. If the person changes app while paused, the existing guard
  copies instead of pasting, so nothing new is needed.
- **Left paused.** After 10 minutes the take finishes by itself and is delivered as any take is. The
  alternative, waiting forever, holds the microphone indicator on.
- **Tests.** State-machine tests through the controller seam (`finishForTests` style), `AudioCaptureLifecycleTests`
  for the gap, and a real-headset check by a person, as the audio rules require.

## Design: a take that dies with the app (not built)

Today a crash or a force-quit during a recording loses that take, because the samples live in memory until
the key is released. Esc, a failure and a lost paste are covered above; this is the one loss left.

- **Journal.** While recording with audio kept on, append the new tail of the sample buffer every second to
  `audio/inflight-<id>.part`, 16-bit mono, encrypted with the same key as `WAVWriter`. Cost: about 32 KB a
  second, one small write, off the audio thread.
- **Normal end.** Delete the journal in the same place the final audio is written or the take is cancelled.
- **After a crash.** At launch, any `.part` file is a lost take. Read it as a cancelled take is read, save it
  as a row, delete the file. Drop files older than 24 hours.
- **Settings.** With "Don't keep" for audio, no journal is written. Keeping no audio means keeping none.
- **Why not built.** It touches the capture path, which needs a real-device check by a person, and it needs
  a decision on the row's label. Test: kill a harness process mid-take and relaunch with a temp home.

## What is not proven

- The acceptance numbers in gap 6 (30 apps with 10 dictations each, 100 five-minute takes, a clipped last
  word at most once in 200) need real apps and real takes. This work proves the logic of the delivery
  paths, not the apps.
- The cost of the key-down read. A native app's known field gets one bounded read of its character count at
  key-down, on top of the facts already read; nothing is read before ⌘V. A person should look at the key-down
  timing before this merges.
- False alarms: a native field whose count lags would open the card for a paste that landed. The card says
  "Check the field first. Your text may already be there." The `late landing=not-landed` log line counts
  them. Whether any app outside the model above behaves like the hidden-input text area is not known; the
  matrix lists the one modelled case.
