# Contributing

## Before you start

- Open an issue first for anything larger than a small fix, so we can agree on the change before
  you spend time on it.
- Every contribution needs a signed contributor licence agreement (CLA.md). See "Signing the CLA"
  below.

## Signing the CLA

We use [CLA Assistant](https://cla-assistant.io) to collect signatures.

1. Open your pull request.
2. CLA Assistant adds a comment and a check named "license/cla".
3. Follow the link in the comment, sign in with GitHub, read the agreement and accept it.
4. The check turns green. A pull request is merged only when every commit author has signed.

You sign once per GitHub account. If a commit's author email is not linked to your GitHub
account, CLA Assistant cannot match it: add the email to your account, or amend the commit.

The CLA lets the maintainers relicense contributions later (CLA.md, section 1). You keep the
copyright in your work. Contributors who want to be listed are added to AUTHORS.

## Making a change

1. Fork the repository and create a branch for one change.
2. Build and test on your Mac (BUILDING.md). `swift build` and `swift test` must pass. There is no
   hosted CI; say in the pull request what you ran.
3. Keep pull requests small and about one thing. Use conventional commit messages
   (`fix: …`, `feat: …`, `docs: …`, `test: …`).
4. For a change you can see in the app, add screenshots in light and dark mode. The app renders its
   screens with `.build/debug/Murmur --snapshots <folder>`.
5. For a cleanup or recognition change, run the evaluation that covers it (Evals/README.md) and put
   the before and after numbers in the pull request.

## Rules the code keeps

- **Local by default.** Nothing leaves the Mac unless the person turned it on, and the screen says
  what is sent. Do not add analytics, network calls or cloud services by default.
- **Never change what the person meant.** Cleanup may fix wording and grammar. It must keep
  certainty, negation, numbers, names and intent.
- **The hot path stays fast.** No disk, database or network work between the key release and the
  paste.
- **Test data is invented or public.** Never put real dictations, recordings or personal data in a
  test, a fixture, an issue or a pull request.
- Swift 6 strict concurrency, files under 800 lines, no force-unwraps of external data.

## Reporting bugs

Open an issue with the macOS version, the Mac model, what you did, what you expected, and what
happened. Do not attach recordings or text you dictated unless you wrote them for the report.
Report security problems privately (SECURITY.md).
