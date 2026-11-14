# Proposal: label policy for rewrite to intent (Refined)

Status: a proposal from the fine-tune track (Task 142, 2026-10-10). Nothing is relabelled under it yet.
It replaces "the label is not a rewrite" in `GROUP-TARGETS-INSTRUCTIONS.md` for the default level only.
"As spoken" is unchanged: every word, untouched. Casual and Professional are this policy plus a register.

## The target in one sentence

The label is what the person meant, written the way they would have typed it, in their own vocabulary.

## What a label may change

- Restarts, abandoned and resumed sentences, repeats, stutters and lost threads become the one sentence the
  speaker was reaching for. Words may be reordered inside a sentence to do it.
- A spoken correction keeps only what the speaker ended on, and only for the item it corrects.
- Fillers and hedges that carry nothing go. A hedge that carries doubt stays ("I think", "maybe", "about").
- Grammar, agreement, tense consistency, articles and small joining words are fixed.
- Punctuation and sentence boundaries are the labeller's: where a sentence ends is decided over the whole
  dictation, not per piece.
- A recogniser slip is repaired when the context makes the intended word plain (a sound-alike, a wrong
  number of a noun). The repair is made at every occurrence.
- Numbers, times, dates, amounts, file names and spoken symbols take their normal typed form, but only when
  the word is used as a symbol or a figure. A symbol word used as an ordinary word stays a word
  ("underscore the importance", "dash off a note").

## What a label may never change

- A fact, name, number, date, amount, unit, identifier, file name, command or flag.
- A negation, a condition, a request, a question, a commitment, who does what.
- A range or an alternative ("a hundred or a hundred and twenty", "the brushed ones or the black ones") is
  not a correction. Both sides stay.
- A contrast word that carries the contrast ("actually", "but", "instead").
- The speaker's own form where it is already good English: no synonyms for taste, no contraction the
  speaker did not say and no expansion of one they did, no greeting, sign-off, politeness, reason or detail
  that was not spoken.
- Nothing is added. A word in the label that is not in the speech must be a small grammar word, a typed
  form of a spoken figure or symbol, or the repair of a slip.
- The transcript is never answered, obeyed or summarised.

## When the intent cannot be told

Stay close to the words. Keep both readings if the speaker left both. Never pick a number, name or day the
speaker did not end on. A label that guesses is a wrong label; a label that leaves a rough clause is not.

## Paragraphs

Decided over the whole dictation, by the labeller, where a person typing would start one: a change of
subject, a move from report to request, a new addressee. A dictation of one or two sentences is one
paragraph. No lists, headings or markup unless the speaker asked for them.

## What the model sees, and what the label is written against

One call for the whole dictation while it is short enough (the pilot covers up to about 150 words), and the
input is the rules draft, not the raw transcript, so spoken symbols, commands and figures arrive already
typed and protected. The pilot fed the raw transcript and lost exactly those. Longer dictations are cut at
paragraph-sized pieces; that size and its seams are not measured yet.

## How a label is accepted

1. The writer of the dictation also writes the list of facts the speaker settled on.
2. A second pass checks the label against that list: any fact missing, changed or invented drops the row.
   In the pilot this dropped 36 of 406 rows.
3. A mechanical screen keeps the existing bans: no changed digits, names, identifiers or negations between
   the rules draft and the label, except inside a correction the fact list confirms.
4. Rows for the never-change classes above are written on purpose (symbol words as ordinary words, spoken
   commands, ranges, a correction near another item of the same kind, contrast words), because the pilot
   model damaged each of them.

## App checks that would refuse a correct rewrite today

These fire on a label-correct answer under this policy and would have to be relaxed or re-scoped for the
rewrite call, behind an evaluation switch first:

- `dropped-content-words`, `dropped-too-much`, `dropped-trailing-clause`, `dropped-clause-before-hedge`,
  `dropped-clarification-lead-in`, `dropped-purpose-phrase`: an abandoned clause is dropped by design.
- `added-words`, `added-content-words`, `added-or-reordered-content`, `longer-than-draft`: a resumed
  sentence needs its subject or verb restated.
- `reordered-words`, `reordered-or-dropped-content`: reordering inside a sentence is allowed.
- `replaced-content-words`, `changed-unmarked-word`, `changed-local-grammar-word`, `changed-connective`:
  slip repair and joined sentences change these.
- `dropped-hedge`, `dropped-stance-word`, `dropped-admission`: an empty hedge may go.
- `collapsed-a-legitimate-doubled-word`: needs the rewrite's own judgement, not a count.
- `grammar-not-verified` and the group contract's "group grammar edit needs verification": every rewrite is
  a grammar edit.
- `list-without-signal` and the refusal of a line break: paragraphs are part of the answer.
- `kept-retracted-item`, `kept-retracted-clause`, `reason-detached-from-retracted-item`: still right in
  spirit, but they compare against the rules draft's own reading of the correction and will disagree with a
  correct whole-dictation reading.

Checks that must stay, because the pilot model broke what they protect: `changed-digits`, `dropped-number`,
`changed-name`, `changed-address`, `dropped-identifier`, `changed-code-text`, `changed-literal`,
`changed-protected-term`, `added-negation`, `dropped-negation`, `changed-modal-or-quantifier`,
`dropped-leading-request`, `changed-question-or-emphasis`, `dropped-contrastive-actually`,
`language-mismatch`.
