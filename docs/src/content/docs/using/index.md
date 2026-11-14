---
title: Using Hushy
description: The keys, the tones, restyling selected text, and notes and meetings.
---

This page describes what Hushy does when you use it. A build from source behaves the same way
except where it says otherwise.

## Dictate

Double-tap fn, talk, and press Return. Hushy transcribes your speech, cleans the text, and pastes
it into the app that has focus. You can also hold fn while you talk. While Hushy is recording or
working, Esc cancels.

Two shortcuts are always on. Control-Command-V pastes your last dictation again, and
Control-Command-C copies it. Every dictation is saved in History even if the paste fails.

Hushy asks for Microphone access to hear you and Accessibility access to paste into other apps.
It asks again when the app is signed with a different identity, which happens after you rebuild
from source with a new certificate.

## Choose a tone

The tone decides how your words are written. Pick a default in Settings.

| Tone | What you get |
|---|---|
| Refined | The default. Fillers, restarts and corrections are resolved, and the grammar is fixed. |
| Professional | The same, in a workplace register. |
| Casual | The same, in a relaxed register. |
| As spoken | Every word you said, including the fillers and the ones you took back. |

Every tone but As spoken writes what you meant, not a word-for-word copy. Cleanup keeps
certainty, negation, numbers and names. [How it works](/how-it-works/cleanup-and-guards/)
explains the checks that enforce this.

## Restyle selected text

Select text in any app and ask for a tone from the right-click Services menu, or use Hushy's
shortcut. The styles are Professional, Casual, Refined and Prompt, which rewrites the text as a
clear prompt for an AI assistant. Hushy never reads your selection or clipboard until you ask.

A rewrite goes through a guard. If the model changes a number, drops a name or drops a "not", Hushy
keeps your original text.

## Notes and meetings

Notes record your voice or a call and produce a title, a summary and action items. A note can be
exported as Markdown or to Apple Notes.

In a build from source, notes and meetings are on in debug builds and in builds made with
`scripts/build-app.sh --meetings-preview`. A normal release build leaves them off.

## Your data

Hushy stores history, notes and settings on your Mac, in a SQLite database under
`~/Library/Application Support/Hushy`. The `HUSHY_HOME` environment variable moves that folder,
which is useful for testing. A build from source sends nothing to the maintainers.
See [Privacy](/using/privacy/).
