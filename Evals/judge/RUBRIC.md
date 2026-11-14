# Judge brief: dictation outputs for developers

You are judging a dictation app. A developer spoke `spoken` (the raw speech-recognition transcript) while typing in the app named by `app` / `windowTitle` (Slack or Teams chat, an email client, a pull-request or issue comment in a browser tab, a Jira comment). The app wrote `written` into that field. The case `id` hints at the audience (teammate, manager, external contact, incident channel, ticket, PR comment).

Read ONLY `judge_input.json` in this directory. Do not open, search for or use any other file. Do not use the web. Judge all {{ITEM_COUNT}} items; do not skip or sample.

## What the app is supposed to do
- `level: clean`: remove fillers ("um", "uh", "like", "you know"), false starts and repeated words; add sentence capitals and punctuation; write spoken symbols, paths, flags, versions, times and numbers the way a developer would type them ("feature slash retry dash logic" -> feature/retry-logic, "dash dash force" -> --force, "eng fourteen twenty three" -> ENG-1423, "p ninety nine" -> p99, "us east one" -> us-east-1); write common acronyms and product names with their normal capitals (PR, API, GitHub, Postgres or PostgreSQL are both fine); lay out an email with greeting, body and sign-off on their own lines. Otherwise keep the speaker's words.
- `level: polished`: everything in clean, plus smoother sentences where the speech rambled. It still must not add facts, drop content or change meaning.
- Neither level is asked to make casual wording formal. Score tone separately (see `sendable`).

## Verdicts per item
- `faithful` (true/false): nothing the speaker meant was added, dropped or changed. Removing fillers and false starts is not dropping. A self-correction ("Tuesday, no, Wednesday") should keep only the corrected version.
- `mechanics` (true/false): capitals, punctuation, layout and every technical token (identifiers, paths, flags, ticket IDs, numbers, times, product names, acronyms) are written as a careful developer would type them for this destination. A chat message that ends without a full stop is acceptable; a missing sentence-initial capital is not, except in a field that is clearly code.
- `sendable` (true/false): a professional could send this exactly as written to this audience without editing a single character. This includes tone: slang that is fine to a teammate may not be fine to an external contact.
- `problems`: zero or more of `meaning_changed`, `content_added`, `content_dropped`, `filler_left`, `technical_token_wrong`, `capital_or_punctuation`, `layout`, `tone`, `other`.
- `note`: at most 20 words, quoting the exact fragment that is wrong. Empty string when all three verdicts are true.

Be strict and literal. Do not give the benefit of the doubt, and do not fail an item for a preference that a careful developer would not notice.

## Output
Output a single JSON array and nothing else (no prose, no code fence), one object per item, in the input order:
{"n": <number>, "id": "<id>", "level": "<level>", "faithful": true, "mechanics": true, "sendable": true, "problems": [], "note": ""}
