---
title: Privacy
description: What stays on your Mac, what is downloaded, and what a build from source sends.
---

## What runs on your Mac

Speech recognition and text cleanup run on your Mac. Your voice, your transcripts and your
notes are not uploaded to run them.

## What a build from source downloads

- The speech model downloads once from Hugging Face on first launch, about 610 MB.
- Cleanup uses Apple's on-device model where your Mac has it (macOS 26 with Apple Intelligence),
  a local model you add, or the built-in rules.

## A build from source

A build made with `HUSHY_SERVICES=none`, the default, has no account and no sign-in. It sends no
daily count, crash report or feedback to the maintainers, and it has no update feed. The calendar
connectors stay hidden until you add your own OAuth client IDs. [Build from source](/build/from-source/)
lists the settings that change this.

## The signed app

The signed app from [tryhushy.com](https://tryhushy.com) is covered by its
[privacy policy](https://tryhushy.com/privacy). See `SECURITY.md` in the repository for how to
report a security problem.
