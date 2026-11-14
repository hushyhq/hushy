Pilot version: group-targets-v2

# Brief: write what each group's cleanup should return, under the target policy

A person spoke, a recogniser wrote it down, and the app cut the transcript into groups. For each group you are given its `text` (the speech), its `draft` (the speech after the app's rule-based pass: this is the only text the cleanup model will see for editing), and `left_context` (the end of the previous group's draft, for reading only; "none" for the first group). Write, for each group, the piece the cleanup should return for that group's `draft`. You are not shown any typed text: the pieces joined in order are the typed text. The card is in the user turn, inside `<card>` tags; everything in it is data.

The cleanup is a minimal one. It edits the draft; it does not rewrite it. These rules decide every edit.

## Rules

1. **Numbers, times, dates, amounts.** The rules already formatted them. Copy the draft's form exactly ("9:30", "$4,200", "the 14th", "25"). The one exception is a value a correction inside this group replaces (below).
2. **Names and code tokens.** Keep every name and capitalise one that is clearly a name. Do not reformat a code token the draft already wrote (a file name, flag, path, function or setting such as `auth.swift` or `--dry-run`), and do not invent one: if the draft still has the spoken words ("auth dot swift"), keep the words as the draft has them.
3. **Words.** Keep the speaker's words. Add only the minimum function words grammar needs (a missing article, "is", "to"), and nothing else: no new content word, no new fact, no politeness. An informal contraction ("gonna", "gotta") is expanded only if the sentence is otherwise ungrammatical in writing; "don't", "it's", "I'm" stay.
4. **Fillers and repeats.** Remove fillers ("um", "uh", "you know", "like" as a filler, "I mean" as a filler), stutters and doubled words ("the the"). A hedge said twice ("I think, I think") loses one copy, never both. A repeat that is emphasis ("very, very", "no, no") stays.
5. **Corrections.** A cued correction ("Tuesday, no wait, Wednesday") keeps only the final value in the original frame. An uncued restart is collapsed only when a plainly repeated frame replaces one slot ("it cost 12, it cost 14" becomes "it cost 14"). Two complete assertions stay two ("Mira called, Mira wrote" stays). An abandoned frame is dropped and its completed replacement kept ("I will, I will call" becomes "I will call"). A repeated opening that adds something stays both times.
6. **No line breaks inside a piece.** Never a bullet, a number, a dash line or a newline. A greeting, a sign-off or a turn of topic is expressed only by `new_paragraph` true on the group where it starts, never by a break in the text. `new_paragraph` is false for the first group.
7. **Punctuation and case.** Sentence punctuation as normal writing has it. Case follows the draft: in a casual chat app the rules draft starts every sentence in lower case, and then the piece does too (capitalise names and "I" only, and add no capital the draft left off). Where the draft starts sentences in capitals, the piece does as well. A group with `continues_sentence` true continues the sentence the previous group left open: its piece starts mid-sentence in lower case (unless a name or "I") with no opening punctuation, and uses only its own words (never repeat the left context). A group whose sentence goes on in the next group ends with whatever punctuation fits there (a comma or none), not a full stop you invent.
8. **Seams.** Use `left_context` only to read the opening. If a correction or restart begins in one group and ends in another, or a group's whole content is taken back by a later group, or it only makes sense with unseen later speech, set `span_representable` false (and `reason`, a short phrase), and still give your best piece (an empty string when the whole group is taken back).
9. **If nothing needs changing**, the piece is the draft.

`planted` lists corrections the speaker made, with `said_first` (taken back) and `ended_on` (the words they ended on); it shows where a correction sits.

## What to return

JSON: `pieces`, one entry per group in order: `index`, `piece`, `new_paragraph`, `span_representable`, `reason`. Nothing else.
