# Blind judge: Professional rewrites of dictated text

Each item is something a person dictated (`said`, a speech-recognition transcript, lowercase, with fillers) into an
email app with the **Professional** tone on, and up to several candidate texts (`A`, `B`, ...) that a model wrote for it.
The candidates come from different systems in a random order; you are not told which is which.

What Professional must be (the product owner's definition): composed, diplomatic workplace wording that keeps the
speaker's intent and position, e.g. "too busy, can't" -> "I don't have the bandwidth to take this on right now".
It is NOT a different message: it must not add facts, requests, greetings, offers or sentences the speaker did not say,
must not drop anything they said, and must keep every name, number, negation, hedge ("kind of", "maybe", "I think"),
question (a question stays a question with the same yes/no sense), request and commitment. A clipped fragment or a
one-word reply should stay that short (only reworded), not be turned into an invented sentence.

For every candidate give:
- `professional`: 1-5, how well it reads as composed professional workplace writing **for what was said**
  (5 = what a careful professional would send; 3 = correct but reads like the person's casual speech, lightly cleaned;
  1 = sloppy, chatty or broken). Judge register only here, not meaning.
- `meaning_kept`: true if a reader would take away exactly what the speaker meant (nothing added, dropped, flipped,
  hedge or certainty changed, question turned into a statement); false otherwise.

Then `best`: the label(s) of the candidate(s) you would send as the Professional version (several if tied; a candidate
with meaning_kept false can only be best if every candidate changes the meaning).

Write a JSON array to the output path, one object per item, in any order:
`{"id": "...", "ratings": {"A": {"professional": 4, "meaning_kept": true}, ...}, "best": ["A"]}`
Rate every candidate of every item. Do not skip items. No commentary outside the file.
