---
title: The pipeline
description: What happens between pressing the key and the text appearing, and what runs on your Mac.
---

A dictation has three stages. A speech recogniser turns audio into words. A cleanup model turns
those words into the text you would have typed. Guards check the result before it is pasted.

```text
microphone -> speech recogniser -> cleanup model -> guards -> paste
```

Every stage runs on your Mac. The one network use in a build from source is the one-time download
of the models.

## Capture

A key listener watches for your gesture. When you start, Hushy records 16 kHz mono audio and
loads the cleanup model while you talk, so it is ready when you stop. A press that is too short,
or audio with no speech in it, is discarded and the pill says so. Whispers are raised to speaking
level before recognition.

## Speech recogniser

Recognition uses a Parakeet model through the
[FluidAudio](https://github.com/FluidInference/FluidAudio) package, on the Apple Neural Engine.
The model downloads once from Hugging Face, about 610 MB. It returns the words you said, including
fillers and restarts, with little punctuation.

## Cleanup

Cleanup turns that raw text into the text you meant. It has two layers.

1. A rule pass runs first and is nearly instant. It handles voice commands such as "new line",
   fillers, stutters, simple spoken corrections like "ten, no, nine", spoken lists, and
   punctuation.
2. A language model handles what rules cannot guess, such as a correction with no cue word. The
   cleaner decides whether to ask it. The model gets a prompt, the raw text and a deadline, and
   answers as JSON with the finished text.

Which language model runs depends on your Mac and your settings. The fallback order in the code is
a local MLX model, then Apple's on-device model, then the rules alone. If a model fails or is not available, the rule
text is used and the dictation still pastes. The cleanup prompt is
`Sources/MurmurCore/Cleanup/IntentCleanupPrompt.swift`, and training uses the same text.

## Guards

The model's answer is checked before it replaces the rule text. A rejected answer falls back to
the rule text. [Cleanup and guards](/how-it-works/cleanup-and-guards/) lists what is checked.

## After cleanup

Your personal dictionary spellings and snippets are applied, and the tone and the app you are
typing into set the final formatting. Hushy then pastes the text with the clipboard and Command-V
and restores your clipboard. The dictation is saved to History after the paste, so saving never
delays it.

## What runs on your Mac

| Step | Where |
|---|---|
| Audio capture and the key listener | On your Mac |
| Speech recognition | On your Mac, after a one-time model download |
| Rule cleanup | On your Mac |
| Language-model cleanup | On your Mac, with Apple's model or a local MLX model |
| History, notes and settings | In a SQLite database on your Mac |

A build from source adds no account, analytics or update check. The signed app the maintainers
ship can send more, only if you turn it on. See [Privacy](/using/privacy/).

## Notes and meetings

A note records your microphone, and for a call the system audio too. The recorder writes audio to
a journal in short segments so a crash does not lose the recording, recognises each segment, and
on stop assembles the transcript. A summariser then writes a title, a summary and action items. It
makes one model call when the transcript fits the model's window and works through overlapping
pieces when it does not.
