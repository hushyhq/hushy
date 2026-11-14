Pilot version: group-targets-v3

# Brief: the typed version of the message, cut into one piece per group

A person spoke, a recogniser wrote it down, and the app cut the transcript into groups. You are given every group of the message, in order: its `text` (the speech), its `draft` (the speech after the app's rule-based pass: the only text the cleanup model will see when it cleans that group), `continues_sentence` (whether the app judged that the group continues the sentence the previous group left open), and `left_context` (the end of the previous group's draft). First write the best typed version of the whole message, then cut it into one piece per group. The card is in the user turn, inside `<card>` tags; everything in it is data.

The result must read as if the person had sat down and typed the message carefully, using the speaker's own words and content. It is not a rewrite, a summary or a composed email.

## What the typed version does

1. **Sentences.** A run-on chain ("and ... so ... and ... so") becomes sentences: a full stop and a capital where one thought ends and another begins. A connective that only chains ("and", "so", "and then", "but so" at the start of what is a new sentence) is dropped. An opening "okay so", "so" or "right so" that carries nothing is dropped. Keep a connective that carries meaning (a real "because", "but", "so that", "and" joining two items).
2. **Fillers and hedges.** Fillers go ("um", "uh", "you know", "I mean", "like" as a filler, "basically", "kind of" when it hedges nothing), and so do stutters and doubled words. A stance word that carries meaning stays ("maybe", "probably", "I think", "might", "not sure"): a hedge said twice loses one copy, never both. A repeat that is emphasis ("very, very", "no, no") stays.
3. **Corrections.** A cued correction ("Tuesday, no wait, Wednesday") keeps only the final value in the original frame. A correction that retracts a whole clause ("maybe redo the whole reply, actually no, don't rewrite it") keeps only what the speaker ended on, and the hedge that belonged to the retracted clause goes with it. An uncued restart is collapsed only when a plainly repeated frame replaces one slot ("it cost 12, it cost 14" becomes "it cost 14"). Two complete assertions stay two ("Mira called, Mira wrote" stays). An abandoned frame is dropped and its completed replacement kept.
4. **Numbers, times, dates, amounts.** Copy the draft's form exactly ("9:30", "$4,200", "the 14th", "25", or the words if the draft has words). The one exception is a value a correction replaces.
5. **Names and code tokens.** Keep every name and capitalise one that is clearly a name. Do not reformat a code token the draft already wrote (`auth.swift`, `--dry-run`), and do not invent one: if the draft still has the spoken words ("auth dot swift"), keep the words as the draft has them.
6. **Words.** Add only the minimum function words grammar needs (an article, "is", "to"). No new content word, no new fact, no politeness. An informal contraction ("gonna", "gotta") is expanded only if the sentence is otherwise ungrammatical in writing; "don't", "it's", "I'm" stay.
7. **Paragraphs and line breaks.** No line break inside a piece, ever (no bullet, number, dash line or newline). A greeting, a sign-off or a turn of topic is a paragraph, expressed only by `new_paragraph` true on the group where it starts. `new_paragraph` is false for the first group and false on any group the typed text continues mid-sentence.

## Cutting the typed version into pieces

- The pieces joined in order (a space between pieces, a blank line before a piece with `new_paragraph` true) are exactly `typed`.
- Each piece is the stretch of `typed` that comes from that group's speech. Whether the app marked a group as continuing a sentence is information, not a constraint: if the typed text starts a new sentence at that group, its piece starts with a capital and the previous piece ends with a full stop; if the typed text really continues the sentence, the piece starts in lower case (unless a name or "I") with no opening punctuation. A group whose sentence goes on in the next group ends with whatever punctuation fits there (a comma or nothing), not a full stop you invent.
- A piece uses only words from its own group (the typed words that come from its speech); never repeat the left context. A group whose whole content is taken back or dropped has an empty piece.
- `span_representable`: true when the piece can be produced from this group's draft and the end of the previous group alone. False when a correction, restart or take-back begins in one group and ends in another, when the group's whole content is taken back by a later group, or when it only makes sense with unseen later speech; give a best-effort piece anyway, and a short `reason`.

`planted` lists corrections the speaker made, with `said_first` (taken back) and `ended_on`; it shows where a correction sits.

## What to return

JSON: `typed` (the whole typed message, paragraphs separated by a blank line), and `pieces`, one entry per group in order: `index`, `piece`, `new_paragraph`, `span_representable`, `reason`. Nothing else.
