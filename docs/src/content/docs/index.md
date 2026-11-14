---
title: Hushy
description: A voice layer for the Mac. Dictation, tones, notes and meetings, with speech recognition and cleanup on your Mac.
---

Hushy is a voice layer for the Mac. You talk and clean text appears where your cursor is. It keeps
what you meant, learns the names you use, and takes notes and meeting notes. Speech recognition
and cleanup run on your Mac.

This site has five parts.

- [Using Hushy](/using/) covers the keys, the tones, restyling selected text, and notes and meetings.
- [How it works](/how-it-works/pipeline/) follows your voice from the microphone to the pasted text.
- [Train your own models](/train/overview/) is a step-by-step recipe that uses public data only.
- [Measure accuracy](/measure/accuracy/) lists the evaluation tools in the repository.
- [Build from source](/build/from-source/) and [Contributing](/contributing/) are for developers.

## Get it running

You need a Mac with Apple silicon, macOS 15 or later, and Xcode 26.

```bash
git clone https://github.com/hushyhq/hushy.git
cd hushy
HUSHY_SERVICES=none scripts/build-app.sh --open
```

The first launch asks for Microphone and Accessibility access and downloads the speech model
(about 610 MB, once). Then double-tap fn, talk, and press Return to paste.

## Source and licence

The source is at [github.com/hushyhq/hushy](https://github.com/hushyhq/hushy) under
GPL-3.0-or-later. The Hushy name and logo are not covered by that licence.
