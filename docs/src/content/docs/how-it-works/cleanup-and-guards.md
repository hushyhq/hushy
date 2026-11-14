---
title: Cleanup and guards
description: What the cleanup model is asked to do, and the checks that keep it from changing what you meant.
---

The cleanup model is allowed to fix wording. It is not allowed to change your meaning. The prompt
asks for the first and the guards enforce the second.

## What the model is asked to do

The system prompt tells the model to write what the speaker meant, as they would have typed it.
That includes resolving restarts, abandoned sentences, repeats and corrections into the sentence the
speaker was reaching for. A correction keeps only what the speaker ended on. Read the full text in
`Sources/MurmurCore/Cleanup/IntentCleanupPrompt.swift`.

The user turn is `Transcript: <raw text>` followed by `Output:`. The model answers with JSON, for
example `{"text": "..."}`.

## What the guards check

The guard is `IntentOutputGuard` in the same folder, with helpers beside it. From its code and
comments, it refuses an answer that:

- holds a value that the spoken words do not support;
- loses a negation, so "do not" never becomes "do";
- is malformed.

Other guards in `Sources/MurmurCore/Cleanup` protect names (`CapitalizedNameGuard`), code
(`CodeTokenGuard`, `CodeContextGuard`), dropped clauses (`DroppedClauseGuard`) and repeated
boundaries (`BoundaryRepeatGuard`). When a register such as Professional rewords on purpose, an
answer that drops a named person is refused and the model is asked again without the register.

The tests in `Tests/MurmurCoreTests` pin these rules. Run them with `swift test`.

## When a guard says no

A refused answer never reaches the page. Hushy uses the rule-based text instead, so the worst case
is text that is less polished, not text that says something different.

## Why training keeps the same shape

The training rows use the same system prompt, the same user turn and the same JSON answer, so a
model you train behaves in the app the way it behaved in training. [Train your own
models](/train/overview/) shows how to build those rows.
