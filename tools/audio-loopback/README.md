# Explicit BlackHole playback and native capture

A local diagnostic utility for synthetic audio. It selects **BlackHole 2ch** directly on an
AVAudioEngine, leaving the macOS default input/output unchanged. With a second argument it
captures channel one from the same virtual device into a new mono float WAV. Existing capture
files are refused. It plays only into a device that is named BlackHole 2ch and has the virtual
transport type, and exits with code 3 when the only device with that name is not virtual. It never
selects the physical microphone or uploads audio.

Compile with the installed Xcode toolchain under the repository's heavy-job lock:

```sh
scripts/mac-heavy.sh compile-loopback swiftc tools/audio-loopback/main.swift -o .build/audio-loopback/play
.build/audio-loopback/play /absolute/path/synthetic.wav /absolute/path/new-capture.wav
```

Playback alone omits the second argument. An app comparison must separately select BlackHole in
the app, start its dictation before playback, stop it after playback, capture its actual delivered
text, and restore its previous input/shortcut. Use CUA for app controls. A capture-device test does
not demonstrate app recognition, paste reliability, or product parity. Competitor output is
strictly evaluation-only.

October 3 verification after installing the official BlackHole 2ch 0.7.1 package and restarting:
a 48 kHz, five-second synthetic frequency sequence yielded 240,000 exactly matching channel-one
samples after aligning a 2,560-frame startup offset (correlation 1, gain 1, RMS error 0). This
single-channel test does not prove stereo identity or arbitrary-device/sample-rate behavior.
The failed FFmpeg live-input capture is retained separately: it omitted samples, so that harness
was not used to establish signal fidelity. Native float WAV can be converted to signed 16-bit PCM
for comparison; file conversion is distinct from the failed live-input path.

Raw artifacts are local/ignored under `Evals/runs/audio-loopback-20261003`. No user recordings are
included in this test, and no system restart is initiated by this utility.
