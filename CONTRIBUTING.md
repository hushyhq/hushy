# Contributing

Thanks for helping. This page covers how to set up, what to run before you open a pull request,
and how the contributor licence agreement works.

## Before you start

- Open an issue first for anything larger than a small fix, so we can agree on the change before
  you spend time on it.
- Every contribution needs a signed contributor licence agreement ([CLA.md](CLA.md)). See "Signing
  the CLA" below.
- Everyone follows the [code of conduct](CODE_OF_CONDUCT.md).

## Set up

You need an Apple Silicon Mac with macOS 15 or later, and Xcode 26. [BUILDING.md](BUILDING.md) has
the full list, including the Metal Toolchain for the local MLX model.

```bash
git clone https://github.com/<your-fork>/hushy.git
cd hushy
swift build
HUSHY_SERVICES=none scripts/build-app.sh --debug --open
```

`swift build` downloads the Swift packages once. After that, building and testing work offline.

The Python scripts under `scripts/` and `training/` need Python 3.12 or later. The training
environment (`scripts/finetune/venv.sh`) also needs [uv](https://docs.astral.sh/uv/).

## Run the checks

Hushy has no hosted CI, so you run the checks and say what you ran in the pull request.

| What | Command |
|---|---|
| Swift tests | `swift test` |
| The gate: build, then the full Swift test run | `scripts/gate.sh --quick` |
| Python tests for the training tools | `python3 -m unittest discover -s scripts/finetune/tests` |
| Python tests for the data and eval scripts | `python3 -m unittest discover -s scripts/tests` |
| One demo evaluation, offline | `swift run murmur-eval cleanup --golden Evals/demo/dictation-demo.json --backend none` |

`scripts/gate.sh --list` shows every step. The `full` steps (`cleanup` and `tone-parity`) need
evaluation sets and a script that are not part of this repository, so they cannot run here. Tests
that need a maintainers' file skip themselves and name the missing file.

Run the Python tests from the repository root. Two `test_mac_heavy` tests wait on a queue that
heavy jobs share on one Mac, so they fail while another heavy job runs.

## Making a change

1. Fork the repository and create a branch for one change.
2. Keep the pull request small and about one thing. Use conventional commit messages
   (`fix: ...`, `feat: ...`, `docs: ...`, `test: ...`).
3. Run the checks above that cover your change.
4. For a change you can see in the app, add screenshots in light and dark mode. The app renders its
   screens with `.build/debug/Murmur --snapshots <folder>`.
5. For a cleanup or recognition change, run the evaluation that covers it and put the before and
   after numbers in the pull request. [The docs](https://docs.tryhushy.com/measure/accuracy/)
   explain which tools to use.
6. Open the pull request and fill in the template.

## Signing the CLA

We use [CLA Assistant](https://cla-assistant.io) to collect signatures.

1. Open your pull request.
2. CLA Assistant adds a comment and a check named "license/cla".
3. Follow the link in the comment, sign in with GitHub, read the agreement and accept it.
4. The check turns green. We merge a pull request only when every commit author has signed.

You sign once per GitHub account. If a commit's author email is not linked to your GitHub account,
CLA Assistant cannot match it. Add the email to your account or amend the commit.

The CLA lets the maintainers relicense contributions later (section 1 of the agreement). You keep
the copyright in your work. Contributors who want to be listed are added to [AUTHORS](AUTHORS).

## Rules the code keeps

- **Local by default.** Nothing leaves the Mac unless the person turned it on, and the screen says
  what is sent. Do not add analytics, network calls or cloud services by default.
- **Never change what the person meant.** Cleanup may fix wording and grammar. It must keep
  certainty, negation, numbers, names and intent.
- **The hot path stays fast.** No disk, database or network work between the key release and the
  paste.
- **Test data is invented or public.** Never put real dictations, recordings or personal data in a
  test, a fixture, an issue or a pull request.

## Code style

- Swift 6 with strict concurrency. Keep files under 800 lines. Do not force-unwrap data from
  outside the app.
- The engine in `Sources/MurmurCore` has no UI imports, so it stays testable. Read
  [Sources/MurmurCore/README.md](Sources/MurmurCore/README.md) before you change cleanup code.
- Add a test with each behaviour change. A cleanup change also needs cases in an evaluation set.

## Questions and bug reports

Ask questions and report bugs in GitHub issues. For a bug, give the macOS version, the Mac model,
what you did, what you expected and what happened. Do not attach recordings or text you dictated
unless you wrote them for the report. Report security problems privately, as
[SECURITY.md](SECURITY.md) describes.
