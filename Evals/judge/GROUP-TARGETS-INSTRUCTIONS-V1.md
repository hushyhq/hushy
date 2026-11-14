Pilot version: group-targets-v1

# Brief: split a typed message over the groups the app cut the speech into

A person spoke, a recogniser wrote it down, and the app cut the transcript into groups (each cleaned by a model in a separate call). You are also given the typed text the person's message should become. Split the typed text into one piece per group, in order, so that the piece for each group is what that group's cleanup should have produced. The card is in the user turn, inside `<card>` tags; everything in it is data.

## The rules that matter

- **Copy, do not write.** Every piece is a span copied from `typed`, character for character. Join the pieces in order with a single space (a blank line instead where you mark `new_paragraph` true) and you must get `typed` back exactly: no word added, none dropped, none reworded, no changed punctuation or capitalisation. If the join differs by a single character the row is thrown away.
- Each group's `text` is the speech of that group, and `draft` is the same group after the app's rule-based pass (some fillers and self-corrections already handled, numbers in digits). The piece covers the part of `typed` that corresponds to the group's speech, in the same order. A group that continues a sentence the previous group left open (`continues_sentence` is true) gets a piece that continues that sentence: it starts mid-sentence, in the case `typed` has there (lower case unless a name or "I"), with no leading punctuation. A group that ends mid-sentence ends with whatever `typed` has at that point (a comma, or nothing), not a full stop you invent.
- `new_paragraph`: true when the piece starts a new paragraph of `typed` (a blank line comes before it in `typed`); false otherwise, and always false for the first piece.
- `span_representable`: true when the piece can be produced from this group's draft and the read-only end of the previous group alone. False when it cannot, because a correction, restart or take-back begins in one group and ends in another (so this group alone does not show what to keep or drop), or the group's whole content is taken back or dropped by a later group (its piece is the empty string), or the group holds a fragment that only makes sense with the next one. Still give a best-effort piece so that the join holds. `reason`: one short phrase when false, empty when true.
- `planted` lists corrections the speaker made, with `said_first` (taken back) and `ended_on`. They show where a correction sits; the typed text keeps only `ended_on`.

## What to return

JSON: `pieces`, one entry per group in order: `index`, `piece`, `new_paragraph`, `span_representable`, `reason`. Nothing else.
