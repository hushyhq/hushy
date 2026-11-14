# Hushy

Hushy is a voice layer for the Mac. You talk and clean text appears where your cursor is. It also
takes notes and meeting notes. Speech recognition and text cleanup run on your Mac.

Documentation is at [docs.tryhushy.com](https://docs.tryhushy.com). It covers using the app, how
it works, how to train your own models, and how to measure accuracy.

## What it does

- **Dictation.** Double-tap fn, talk, press Return. Hushy pastes the text you meant, with fillers,
  restarts and corrections resolved.
- **Tones.** Refined (the default), Professional, Casual, or As spoken to keep every word.
- **Notes and meetings.** Record a note or a call and get a summary with action items. In a build
  from source they are on in debug builds and in `scripts/build-app.sh --meetings-preview` builds.

## Install

Download the signed app from [tryhushy.com](https://tryhushy.com). Hushy is free.

## Build from source

You need an Apple Silicon Mac with macOS 15 or later, and Xcode 26.

```bash
git clone https://github.com/hushyhq/hushy.git
cd hushy
swift build
swift test
HUSHY_SERVICES=none scripts/build-app.sh --open
```

The first launch asks for Microphone and Accessibility access and downloads the speech model
(about 610 MB, once). A build from source has no account and sends nothing to the maintainers.
[BUILDING.md](BUILDING.md) has the details, including what each build setting does.

## Train your own models

This repository holds the recipe for the on-device cleanup model and the meeting-extract model, and
the tools that measure them. The recipe uses public data only. Step-by-step instructions are at
[docs.tryhushy.com/train/overview](https://docs.tryhushy.com/train/overview/).

Two things are not here. The weights of the models we ship are not released yet, and the dataset
we trained them on is not published. Both are explained in the docs and in
[training/README.md](training/README.md).

## Contribute

Read [CONTRIBUTING.md](CONTRIBUTING.md). In short, open an issue for anything large, keep a pull
request to one change, and say what you ran. Your first pull request asks you to sign the
contributor licence agreement ([CLA.md](CLA.md)) through CLA Assistant. Everyone is expected to
follow the [code of conduct](CODE_OF_CONDUCT.md). Report security problems privately, as
[SECURITY.md](SECURITY.md) describes.

## Licence

Hushy is free software under the GNU General Public License, version 3 or any later version
([LICENSE](LICENSE)). Third-party notices are in [NOTICE](NOTICE).

The Hushy name and logo are not covered by that licence. If you distribute a build, give it another
name and icon. [TRADEMARKS.md](TRADEMARKS.md) has the rules.
