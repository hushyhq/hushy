# How contributor licence agreements are checked

This repository uses [CLA Assistant](https://cla-assistant.io), a hosted GitHub app. It runs no
GitHub Actions workflow.

- The agreement contributors sign is [CLA.md](../CLA.md). CLA Assistant shows the same text, kept
  in a GitHub gist that the maintainers link to this repository.
- On every pull request, CLA Assistant sets the "license/cla" status and comments with a signing
  link for any commit author who has not signed.
- Branch protection on the default branch requires the "license/cla" status before a merge.
- If the agreement text changes, the gist and CLA.md change together, and contributors are asked to
  sign the new version.

Contributors: see "Signing the CLA" in [CONTRIBUTING.md](../CONTRIBUTING.md).
