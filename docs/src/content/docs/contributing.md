---
title: Contributing
description: How to propose a change, what to run first, and how the contributor licence agreement works.
---

The full guide is [`CONTRIBUTING.md`](https://github.com/hushyhq/hushy/blob/main/CONTRIBUTING.md) in
the repository. This page covers the parts you need first.

## The short version

1. Open an issue for anything larger than a small fix.
2. Fork the repository and make a branch for one change.
3. Run `swift build` and `swift test`, plus the Python tests that cover your change. There is no
   hosted CI, so say in the pull request what you ran.
4. Open a pull request. A bot called CLA Assistant asks you to sign the contributor licence
   agreement on your first one.

## Checks

```bash
swift test
scripts/gate.sh --quick
python3 -m unittest discover -s scripts/finetune/tests
python3 -m unittest discover -s scripts/tests
```

`scripts/gate.sh --quick` builds the package and then runs the full Swift tests with a throwaway
home folder, so your real Hushy data is not touched. `scripts/gate.sh --list` shows every step. The
steps marked `full` need evaluation sets that are not in this repository.

## The contributor licence agreement

The agreement lets the maintainers relicense contributions later. You keep the copyright in your
work. You sign once per GitHub account, through a link in CLA Assistant's comment on your pull
request. The text is [`CLA.md`](https://github.com/hushyhq/hushy/blob/main/CLA.md).

## Rules the code keeps

- Nothing leaves the Mac unless the person turned it on.
- Cleanup never changes what the person meant.
- The path between key release and paste does no disk, database or network work.
- Tests use invented or public data. Never put real dictations in a test or an issue.

## Questions and security

Ask questions and report bugs in GitHub issues. Report security problems privately, as
[`SECURITY.md`](https://github.com/hushyhq/hushy/blob/main/SECURITY.md) describes.

## Licence and name

Hushy is GPL-3.0-or-later. The Hushy name and logo are not covered by that licence, so a fork
needs its own name and icon.
