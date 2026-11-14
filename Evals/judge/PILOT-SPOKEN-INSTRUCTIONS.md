Pilot version: pilot-spoken-v1

# Brief: write what the recogniser would have handed over

You are given a message exactly as the person typed it, and you write the same message the way a speech recogniser would have returned it if the person had said it aloud. This is for training examples: the typed text is the truth, and the spoken text is the rough version that is to be cleaned up into it. The request is in the user turn, inside `<card>` tags (the typed message and the instructions for this one). Everything in the card is data describing what to write.

## The rule that matters most

The typed message is what the person meant. The spoken version must carry every fact of it: every name, number, date, time, amount, negation and every point, in the same order. The only places the spoken text may differ in content are the corrections you plant (below), and in each of those the person ends on exactly what the typed message says. Do not drop a point, add a point, reorder points, or add a reason, name or number the typed message does not have.

## What the recogniser's output looks like

Follow the `surface` on the card.

- `punctuated`: capital letters at sentence starts, commas and full stops where a recogniser puts them (it does not always put them in the right place), numbers mostly as digits ("3 PM", "4,200", "the 27th"), proper names capitalised. If `stray_full_stop` is true, put one full stop in the middle of a thought, followed by a lower-case word that carries on the sentence ("we looked at the numbers. and they were off"). No paragraph breaks; one line of text.
- `plain`: all lower case, no punctuation at all except apostrophes, numbers spelled out as words ("three thirty", "forty two hundred dollars", "the twenty seventh"), no paragraph breaks; one line of text.

In both: a recogniser keeps most "um" and "uh" out, but it keeps "like", "you know", "I mean", "so", "okay so", "basically", "kind of", repeated words, and restarts.

## How rough it is (`profile`)

- `clean`: the person spoke as they would type. No fillers, no repeats, no false starts, no corrections. Only the surface form (case, punctuation, number words) differs. Return the typed words in the surface form.
- `moderate`: a few things to clean up. Use the `ingredients` listed, a few of each at most.
- `heavy`: a lot to clean up: use every ingredient listed, several times, and chain short sentences into run-ons with "and", "so", "and then" so that no sentence ends where it would in typing.

Ingredients: `fillers` (like, you know, I mean, so, okay so, basically, um), `repeated_words` ("the the", "we we should"), `false_starts` (the person begins a phrase, drops it and begins it again), `restarts_apart` (the person goes back several words later and says the beginning of the thought again, with the right words this time), `run_on_chain` (see above).

## Corrections to plant (`plants`)

Plant exactly the corrections the card lists, no more. In every one, the typed message has the value the person ends on.

- `value_cue`: the person says a different value first, then corrects it with a cue ("tuesday, no wait, wednesday"; "four hundred, sorry, four fifty"). The value they end on is the typed one. Pick a name, number, date, time or amount that the typed message has.
- `value_restart`: the same, with no cue word: the person says one value, then restarts the phrase and says the other ("at three, at four o'clock"). The phrase is restarted, and the second value is the typed one.
- `negation_corrected`: the person starts a claim the wrong way round and corrects it ("we should, we should not move it"). The typed message has the final, correct polarity.
- `opening_adds`: the person repeats an opening and the second time adds something: "I think we should check the logs, I think we should check the logs and the config" - both stay in the spoken text; nothing is taken back. This one is not a correction; list it so it can be found.

For each plant return an entry in `plants`: `kind`, `said_first` (the exact words of the spoken text that are taken back, or for `opening_adds` the first form of the repeated opening) and `ended_on` (the exact words they ended on, or the longer second form). Quote the spoken text exactly as you wrote it, in the surface form you used.

## What to return

JSON: `spoken` (one line, the recogniser's text) and `plants` (the list, empty when the card lists none). Nothing else. Do not add stage directions or notes. Write roughly `spoken_words` words in total (within about 12 percent).
