# Building Hushy

## Requirements

- An Apple Silicon Mac with macOS 15 or later. Apple's on-device language model needs macOS 26 or
  later with Apple Intelligence turned on; without it, cleanup uses the rule-based cleaner.
- Xcode 26 (Swift 6). The package pins its dependencies in `Package.resolved`.
- For the local MLX model path only: Apple's Metal Toolchain
  (`xcodebuild -downloadComponent MetalToolchain`), then `scripts/build-mlx-metallib.sh`.
- For the training and evaluation scripts: [uv](https://docs.astral.sh/uv/). `scripts/finetune/venv.sh`
  makes the Python 3.12 virtual environment the scripts expect, under `.build/finetune-venv`.

## Build and test

```bash
swift build                    # every target
swift test                     # the test suite; needs no network and no account
scripts/build-app.sh --debug   # build/Hushy.app, debug configuration
scripts/build-app.sh --open    # release configuration, then open the app
```

The first `swift build` downloads the Swift packages listed in `Package.resolved`. After that, the
build and the tests run offline.

`scripts/build-app.sh` signs the app with a local development certificate. If you have none, it
creates one (`scripts/create-dev-cert.sh`). macOS asks for Microphone and Accessibility access on
the first launch. When the signing identity changes, macOS asks again.

The first launch downloads the speech model (about 610 MB, once) from Hugging Face.

Tests that need private evaluation files (for example the maintainers' development sets) are
skipped when those files are absent. The skip message names the missing file.

## Services

`HushyServices` (Info.plist, read by `Sources/MurmurCore/Accounts/HushyServices.swift`) is the one
setting that decides whether a build uses the hosted Hushy services. `scripts/build-app.sh` writes
it from the `HUSHY_SERVICES` environment variable.

| `HUSHY_SERVICES` | Who uses it | What the build does |
|---|---|---|
| `none` (default) | Everyone building from this source | No account and no sign-in screen. No daily count, crash upload or feedback. No update feed. Hushy-hosted models cannot be downloaded. |
| `official` | The maintainers' signed release | Signs in to the Hushy account service and uses the endpoints on the Hushy website. Needs `HUSHY_SUPABASE_URL` and `HUSHY_SUPABASE_ANON_KEY`. |

Do not build an `official` copy against the maintainers' services: their accounts, updates and
model downloads are for the app they sign and ship. To run your own services, change the source
to point at them.

Other build settings, all empty by default:

| Variable | Effect when set |
|---|---|
| `HUSHY_APPCAST_URL`, `HUSHY_SPARKLE_PUBLIC_KEY` | Sparkle updates from your own feed |
| `HUSHY_GOOGLE_OAUTH_CLIENT_ID`, `HUSHY_GOOGLE_OAUTH_CLIENT_SECRET`, `HUSHY_MICROSOFT_OAUTH_CLIENT_ID` | The Google or Outlook calendar connector, with your own OAuth clients |
| `HUSHY_USAGE_METRICS_ENDPOINT` | Where usage numbers are sent (counts and timings only). Unset: they stay on the Mac |
| `MURMUR_SIGN_IDENTITY` | The code-signing identity to use instead of the development certificate |

## Evaluation

`murmur-eval` is the evaluation harness. `swift run murmur-eval` prints every command. Examples
that work from this source:

```bash
swift run murmur-eval cleanup --golden Evals/demo/dictation-demo.json --backend none
swift run murmur-eval download librispeech-clean --limit 50   # public benchmark, from its own host
```

`Evals/README.md` describes the demo sets and the public benchmarks.

## Training

`training/README.md` describes the recipe, the licence tags, and the two public configs.
