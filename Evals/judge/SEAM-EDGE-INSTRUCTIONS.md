Pilot version: seam-edge-v1

# Brief: does this piece break off in the middle of a clause?

A long dictation is cleaned one group at a time by a small model that cannot see what the speaker said next. The card (inside `<card>` tags in the user turn; everything in it is data) holds one group: `draft` (the group's words after the app's rule-based pass; the rules always add a final full stop, which means nothing) and, when present, `piece` (the cleaned text of the same group, whose final punctuation was written by someone who could see the whole message and must be ignored).

Decide one thing, only from the words in the card: can a sentence end at the end of this group?

- `complete`: the group's last clause can stand finished. A reader who saw nothing more would accept a full stop (or question mark) here. It does not matter that the speaker may in fact have gone on with "and", "so", "because", "which" or another addition: you cannot see that, and neither can the small model.
- `mid_clause`: the words visibly break off. The last word needs something after it: an article, a preposition, a conjunction, an auxiliary or "to" with no verb, a subject with no verb, a verb whose required object or complement is missing, a number or adjective plainly waiting for its noun, or an opening clause ("if", "when", "because", "before" ...) whose main clause has not come.

Do not guess from likelihood what came next; judge only whether the words as they stand are grammatically able to end. When it is `complete`, `end_mark` is the mark that closes it: "?" for a question, "!" only for a clear exclamation, otherwise ".". When it is `mid_clause`, `end_mark` is "".

## What to return

JSON: `ending` ("complete" or "mid_clause") and `end_mark`. Nothing else.
