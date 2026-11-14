# Hushy

Hushy is a dictation and meeting-notes app for the Mac. Hold a key, speak, let go, and clean text
appears where your cursor is. Speech recognition and cleanup run on the Mac.

This repository holds the source of the app, the training recipe and pipeline for its models, and
the tools we use to evaluate them. It is a snapshot of the maintainers' working repository, made
from an allowlist; history before the snapshot is not included.

## What is here

| Part | Where | What it is |
|---|---|---|
| The app | `Sources/Murmur`, `Sources/MurmurCore`, `Sources/HushyModels*`, `Sources/HushyObjC` | Every Swift target the app is built from |
| Command-line tools | `Sources/murmur-mcp`, `Sources/murmur-eval`, `Sources/murmur-bench`, `Sources/hushy-*` | The MCP helper, the evaluation harness, benchmarks, and maintainer tools |
| Tests | `Tests/` | `swift test` runs them with no network and no account |
| Training recipe | `training/`, `scripts/finetune/`, `scripts/meeting-extract/`, `scripts/retrain_*.py` | Data builders with per-row licence tags, the commercial-only filter, trainer configs |
| Evaluation | `Sources/murmur-eval`, `scripts/*_score.py`, `scripts/api_judge*.py`, `Evals/` | Runners, scorers, judge rubrics, small invented demo sets, public-benchmark downloaders |

## What is not here

- **Datasets.** No training data, no labels, no development, held-out or sealed evaluation sets.
  The recipe downloads public corpora from their own hosts and never mirrors them.
- **Model weights.** See below.
- **The hosted services.** The account service, the model host, the update feed, the website and
  their keys are run by the maintainers and are not part of this source.

## Model weights

The weights of Hushy's own cleanup models are not released yet. For now, the app the maintainers
sign and ship downloads those models after the person signs in.

We are not releasing the current weights, for these reasons:

- **Training-data licences.** Some training rows come from sets we may not redistribute in a
  model: research-only sets, GPL-licensed rows, and rows with no stated licence.
- **Model-written labels.** The training targets were written by large language models from
  several providers. We have not finished reviewing those providers' terms for releasing models
  trained on such labels.

The path to open weights:

1. Retrain on commercial-safe sources only. `scripts/finetune/licence_filter.py` drops every row
   whose source is not on the commercial-safe list, and every row without a source.
2. Publish each weight with a licence manifest that shows zero non-commercial rows.
3. Publish those weights openly, each under its own licence.

`training/configs/` holds the public configs for that retrain.

You do not need the weights to use a copy you build yourself. With `HushyServices = none`,
dictation works with no account: speech recognition runs on the Mac, and cleanup uses Apple's
on-device model where your Mac has it, or the rule-based cleaner.

## Build it

You need an Apple Silicon Mac with macOS 15 or later (macOS 26 or later for Apple's on-device
model) and Xcode 26. [BUILDING.md](BUILDING.md) has the details.

```bash
swift build
swift test
scripts/build-app.sh --open
```

## A copy you build yourself

A build from this source uses no Hushy service (`HushyServices = none`):

- There is no account and no sign-in screen. Dictation works without an account.
- Nothing is sent to the Hushy website: no daily count, no crash reports, no feedback.
- It is not offered the maintainers' updates.
- The calendar connectors stay hidden until you add your own OAuth client IDs.
- The Hushy-hosted cleanup models cannot be downloaded. The speech model downloads from Hugging
  Face as usual. Cleanup uses Apple's on-device model where your Mac has it, or the rule-based
  cleaner.

Details: [BUILDING.md](BUILDING.md#services).

## Licence

`SPDX-License-Identifier: GPL-3.0-or-later`

Copyright (C) 2026 The Hushy Authors ([AUTHORS](AUTHORS)). Hushy is free software under the GNU
General Public License, version 3 or (at your option) any later version ([LICENSE](LICENSE)).
Third-party code and data notices are in [NOTICE](NOTICE). The Hushy name and logo are not licensed:
[TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need a signed contributor licence agreement
([CLA.md](CLA.md)); CLA Assistant asks you to sign it on your first pull request. Report security problems privately: [SECURITY.md](SECURITY.md).
