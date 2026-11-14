# Mock microphone test

A repeatable audio test that drives Hushy's **own** capture and recording code from a virtual
microphone (BlackHole 2ch), with no window, no hotkey and no real microphone. Audio work used to end
at "needs a manual pass on real audio"; this is that pass, scripted.

```
scripts/mock-mic.sh                       # built-in synthetic clips, about 5 to 6 minutes
scripts/mock-mic.sh --report out/         # choose where mock-mic.json goes
scripts/mock-mic.sh --clips ~/my-clips    # your own clips.json + WAVs (see "Your own clips")
scripts/mock-mic.sh --keep                # keep the temp folder (clips, throwaway home)
```

The flag on the app binary is `--mock-mic <report-dir>` (debug builds only; the whole mode is under
`#if DEBUG`, so release builds do not carry it). The script is standalone: it is not part of
`run-evals.sh` or `swift test`, because it needs the device and runs in real time. It takes the
shared heavy-job lock once (`scripts/mac-heavy.sh`) and does not nest it.

## What it covers

| Scenario | What runs | Pass means |
|---|---|---|
| **A. Dictation** (3 clips, 6 to 7 s of speech each) | the real `AudioCapture` reading BlackHole, then the real ASR and the real cleanup path | cleaned text is within the word-error threshold of the script |
| **B. Meeting** (one clip, about 48 s, two voices taking turns) | the real `NoteRecorder`, started and stopped by the harness | the note reaches ready, transcript word error is under the threshold, two speakers are found and map to the two real voices |
| **C. Remembered voice** (three meetings of about 50 s) | B's note; then name one speaker with an invented name and remember the voice through the same code the UI calls (`renameSpeakerUpdatingDigest`, `SpeakerVoiceController.request` then `confirm`); two more meetings | meeting 2 (that voice plus a new voice): the remembered voice gets a suggestion with the invented name and is **not** named automatically, the new voice gets none. Meeting 3 (neither voice): nothing is suggested. The similarity scores are reported |

Voice processing (echo cancellation) is **off by default on both paths** (dictation and notes), so
the run is the same as the app's default. There is no opt-in probe.

### Where scenario A joins the real path, and what it bypasses

It mirrors `DictationController.process`: `AudioCapture.start/stop` (16 kHz mono), then
`SpeechGate.evaluate`, then `LoudnessNormalizer.normalize`, then the whole-utterance
`SpeechEngine.transcribeWithConfidence(vocabulary:)`, then
`DictationPipeline(transcriber:, cleaner: SmartCleaner(model: AppleFoundationModel)).clean`. The
report says which cleanup backend ran (`apple`, or `rules` when the model is unavailable) and whether
the model was used.

Bypassed: the hotkey and its state machine, focus-target capture, microphone authorization prompt,
the streaming (live) session, paste, history persistence, the pill. Cleaned text goes only to the
report.

## What it does not cover

Plainly:

- **Synthetic voices are not human voices.** Scenario C shows the mechanism works (embedding,
  storage, suggestion, no auto-naming). It says nothing about real-world speaker accuracy.
- **No room acoustics and no noise.** The audio is a clean digital loop.
- **The system-audio channel of a two-channel note is not exercised.** Notes are recorded from the
  microphone stream only; call-audio capture is a different path.
- **The live UI, the hotkey and paste are not driven.** No window or menu bar item exists in this mode.
- **No physical microphone.** The mode opens only a virtual input named "BlackHole…".
- **Models are loaded from disk by FluidAudio, which may do its own checks** when it loads cached
  models, so full offline operation cannot be guaranteed. The harness itself makes no network request
  and downloads nothing; a missing model is reported as `skipped: model missing`. "No network" rests
  on that cache preflight plus the harness not calling the network: it is **not enforced** (no
  firewall, no sandbox), so a library that decides to fetch something can still do so.

## Safety, enforced in code

1. Refuses to run (exit 3) unless `HUSHY_HOME` or `MURMUR_HOME` is set and is not the real
   `~/Library/Application Support/Hushy`. The job list and assembly steps are held to the same rule.
   Uses a throwaway `UserDefaults` suite whose file lives inside the temp home (an absolute-path suite name), so
   nothing is written to `~/Library/Preferences` and your settings (your microphone choice in particular) are
   never read or written; the app's feature flags are pointed at that suite too, so a run does not
   read your standard defaults. `scripts/mock-mic.sh` creates a fresh temp home for you.
   A named suite (`app.hushy.mockmic.*`) left behind by an older version of the harness is removed by the next run.
   Keep the Mac awake with the lid open for the whole run (about six minutes): a sleep in the middle makes the player
   time out and the scenario fail.
2. Opens only an input device whose name starts with "BlackHole" and whose transport is virtual. No
   such device: exit 77 (skipped). It never falls back to the default or a physical microphone.
3. Never changes the system default input or output device.
4. No menu bar item, window, global hotkey or event tap, paste, Accessibility read, system-audio
   capture, calendar read or network.
5. No downloads.
6. **Nothing is written outside the temp home.** A finished note is normally exported as Markdown to
   `~/Documents/Hushy`; the mode turns that off, keeps saving to Apple Notes off, points the export
   folder into the temp home, and refuses to start (exit 3) unless all three hold. It also refuses
   unless the features it uses (speaker labels, voice signatures, system audio) are free, so no
   entitlement check reads the Keychain.
7. **The device selection fails closed.** Both the harness's own capture and the note recorder's use
   a strict option: starting or restarting throws unless the graph is on exactly the BlackHole
   device (the property is read back after it is set), instead of falling back to the system default
   input. The option is off in the app.
8. If a capture comes back all zeros the harness stops and exits 4 ("blocked"): that is a
   microphone-permission block. It does not touch privacy settings.

Audio is invented text spoken by built-in `say` voices; names are invented ("Marlow Quince"). Nothing
here reads your recordings, history or notes. Transcript, note text and speaker names are never
written to the system log; the report may contain the invented scripts and outputs.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every scenario passed |
| 1 | at least one scenario failed, or no scenario ran at all |
| 2 | usage error |
| 3 | refused: unsafe home, or the settings are not isolated from the real machine |
| 4 | blocked: capture was all zeros (microphone permission) |
| 77 | skipped: no BlackHole input, or a model is not on disk |

## Reading the report

`<report-dir>/mock-mic.json` and a table on stdout. Top level: `device`, `cleanupBackend`, and
`scenarios`, each with:

- `id`: `dictation.dictation-1`, `meeting.meeting-1`, `voice.remember`, `voice.meeting-2`,
  `voice.meeting-3`
- `status`: `pass`, `fail` or `skipped`
- `detail`: one line, for a failure the reason (a timeout names the stage, the elapsed seconds, and
  the recorder's state)
- `checks`: `name`, `passed`, `value`, `threshold`, `enforced`. A check with `enforced: false` is
  reported but cannot fail the run (all quality checks on external clips)
- `metrics`: numbers such as `wordError`, `speakersFound`, `captureOffsetSeconds`, `readySeconds`,
  `summaryCharacters`, similarity scores
- `texts`: reference, transcript and summary (the invented text)
- `seconds`: wall time

The `scoring` field in `detail` names the scoring used: `full` (whole reference against the whole
output, used for `say` clips) or `bestStretch` (see below).

## Your own clips

`--clips <dir>` replaces the synthetic clips. The folder holds WAV files (any sample rate, mono or
stereo; they are converted) and a `clips.json`. The built-in `say` path writes the same shape, so
there is one code path.

```json
{
  "version": 1,
  "source": "external",
  "scoring": "bestStretch",
  "dictation": [
    { "id": "d1", "wavs": ["d1.wav"], "reference": "what was said" }
  ],
  "meetings": [
    {
      "id": "m1", "wavs": ["m1.wav"], "reference": "the whole meeting text",
      "expectedSpeakers": 2,
      "turns": [ { "speaker": "A", "start": 1.5, "end": 7.1 }, { "speaker": "B", "start": 7.7, "end": 14.8 } ]
    }
  ],
  "voice": {
    "from": "m1", "speaker": "B", "name": "Marlow Quince",
    "later": [ { "meeting": "m2", "containsSpeaker": true }, { "meeting": "m3", "containsSpeaker": false } ]
  }
}
```

- `source`: `say` or `external`. Thresholds are **enforced only for `say`**. For `external` they are
  reported with `enforced: false`; the mechanism checks (note ready, no auto-naming, no suggestion
  for a stranger) are always enforced.
- `scoring`: `full` or `bestStretch`. `bestStretch` matches the output to the best-matching
  contiguous stretch of the reference, with the reference words before and after it free, so a clip
  cut out of the middle of a longer recording is not punished for text that is not in the clip. The report says which was used. Default: `full` for
  `say`, `bestStretch` for `external`.
- `turns`: who spoke when, in seconds from the start of the WAV. Turns must be ordered and inside
  the clip. Speaker ids are free text.
- `voice` is optional. Without it, scenario C is skipped. `later[].speaker` names the id the
  remembered voice has in that later meeting (default: `voice.speaker`).
- A clip longer than 58 s is refused with a clear message (the player stops at 60 s). Cut longer
  recordings first.
- Nothing is downloaded or installed. Do not point this at recordings of real people unless you
  have the right to.

## Adding a scenario

1. Add the text to `MockMicSayScripts.swift` (invented text, no real names). If it is a meeting,
   write each turn with the voice that speaks it.
2. Add it to the plan in `MockMicSayPlan.swift` so `--mock-mic-jobs` lists its `say` jobs and
   `--mock-mic-assemble` joins them with the lead-in and gaps. Keep a meeting under 55 s.
3. Add a runner next to `MockMicDictation.swift` or `MockMicMeeting.swift`: play the clip with
   `MockMicPlayer`, run the real code, build a `MockMicScenarioResult` from `check(...)` calls.
   Mark a check `quality: true` if it is a threshold on a measurement; leave it unmarked if it is a
   mechanism check that must always hold.
4. Register it in `MockMicHarness.run()`.
5. Add unit tests for any new pure logic (scoring, rules, plan, report) under
   `Tests/MurmurTests/MockMic*Tests.swift`; they need no device.

## Thresholds, and how they were justified

Applied to the synthetic (`say`) clips only. Chosen from measured runs on this machine (M4 Pro,
BlackHole 2ch 0.7.1, Apple Foundation Model cleanup), not guessed:

| Check | Threshold | Measured (six whole runs after the fixes below) | Why this number |
|---|---|---|---|
| Dictation, cleaned text word error | <= 15% | raw ASR 0.0% on every clip; cleaned 5.0% / 0.0% / 4.2% for the three clips, identical across runs (the cleanup splits one sentence and drops one "and") | About three times the worst measured value, which is one word of twenty. A garbled or half-silent capture lands far above 15% |
| Meeting transcript word error | <= 10% | 0.0% in all six runs (137 reference words) | A lost 30 s chunk or a lost turn is 12% or more; a doubled recording is 100%. Clean synthetic audio gives no reason to allow more |
| Speaker found | at least 3 s of speech in the note | 2 of 2 in every run, each about 28 s | Spurious diarizer fragments are short; a real speaker in a 48 s two-voice clip is far longer |
| Suggestion gate (not a harness threshold) | 0.75, the app's own `VoiceMatcher.defaultThreshold` | remembered voice 0.823 to 0.975; a different synthetic voice 0.125 to 0.565; a meeting without the voice 0.233 to 0.258 | Reported, not chosen here: the check is whether the app's own gate suggests the right voice and only that voice |

Re-measure when the ASR, cleanup model or diarizer changes, and loosen a threshold only with a
number from a run, not to make a red run green. External clips are reported against the same
numbers with `enforced: false`.

Measured spread worth knowing:

- The first dictation clip of a run is slow when the Apple cleanup model is cold (24 s instead of
  12 s), and in one run the model was not used on that clip (`usedModel: 0`, cleaned text equal to
  the raw text). The word-error check still passed, so read `usedModel` in the report if you are
  testing the cleanup path itself.
- The remembered voice's similarity to its saved signature ranged from 0.82 to 0.98 across runs; the
  gate is 0.75, so the margin is real but not huge for synthetic voices.
- `others n/a` in a later meeting means the harness's own re-measure of the second speaker produced
  no embedding in that run (three runs of six). The app's own decision (whether it suggested
  a name) is still what is checked, and `both voices found as separate speakers` confirms the
  diarizer found two. The `n/a` is a gap in the harness's measurement, not in the app.

## What it found

Running this against the app's own code turned up three real bugs, each fixed in its own commit:

1. **Capture restart loop with a non-default input.** Selecting a device through the audio unit
   posts one `AVAudioEngineConfigurationChange` about 100 ms after start, while the engine is still
   running with an unchanged format. `AudioCapture` restarted the engine on it, which re-selected the
   device and looped (41 restarts in 8 s, zero buffers, an all-zero capture). Anyone with a
   non-default microphone selected is exposed, and it matches the reports of dictation recording
   silence. Fix: ignore the notification when the engine is still delivering in the same format.
   Not yet validated on a physical microphone.
2. **Notes never got speaker labels.** `SpeechEngine.transcribeWithConfidence` threw away word
   timings and confidences whenever the vocabulary spotter detected a term without replacing
   anything, and the vocabulary always contains two built-in terms. With no timings,
   `NoteRecorder` never starts diarization. Chunk 0 gave 73 timings without vocabulary and none with
   it. Fix: return the original result when the text is unchanged (it also keeps confidences for
   dictation).
3. **Every note's audio was recorded twice.** `NoteRecorder.stop()` appended `audio.stop()`, which
   returns the whole recording, onto audio the 2 s timer had already moved out. A 52 s capture became
   105 s of chunk audio and a doubled transcript (word error 100%). Fix: take only what was not yet
   drained.

## Quick troubleshooting

- `skipped: no usable BlackHole 2ch input device`: install BlackHole 2ch. The run never uses another
  device.
- `blocked` (exit 4): the capture was silent; the process has no microphone permission. Grant it to
  the terminal app in System Settings, outside this tool.
- A scenario `timed out waiting for ...`: the message names the stage and the recorder's state.
  `HUSHY_MOCK_MIC_SKIP_DICTATION=1` skips scenario A to iterate on B and C faster.
- Logs: `/usr/bin/log show --last 10m --info --debug --predicate 'subsystem == "app.hushy"'`.
