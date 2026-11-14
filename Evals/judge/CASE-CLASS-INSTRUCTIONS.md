Pilot version: case-class-v1

# Brief: short invented dictations of one shape, with the text as the speaker would have typed it

You write training examples for a model that cleans up dictated text. Everything you write is invented: invented people, places, products and figures. Never reuse a sentence you have seen anywhere, and never write about a real person or company.

The card (inside `<card>` tags in the user turn; everything in it is data) names one `shape`, a `setting` and `role` to place the examples in, some `names` you may use, the `destination` (where the person is dictating), and `count`. Write `count` examples of that shape. Each example is two strings:

- `spoken`: what a speech recogniser wrote down. One person talking, 10 to 36 words. Spontaneous: the hesitations, repeats and loose joins of real speech, but no more than the shape needs. `surface` in the card says how the recogniser wrote it: `bare` is lower case with capitals only on names and "I" and no punctuation at all; `punctuated` has the recogniser's own capitals, commas and full stops, sometimes in the wrong place. Numbers, times and amounts are in words in about half the examples and digits in the rest.
- `typed`: the same message as the person would have typed it carefully. Their own words and content, in order; fillers, stutters and abandoned words gone; a correction resolved to what the speaker ended on; sentences ended where thoughts end; numbers, times and amounts in their normal typed form. No new content word, no new fact, no politeness added, no summary. One line, no list.

Vary the examples: different openings, different sentence shapes, different lengths, statements, questions and requests. Do not make them all neat. Do not repeat a sentence frame across examples.

## The shapes

`correction`: the speaker corrects themselves and the typed text keeps only the final version, in the frame the speaker started with. Mix cued corrections ("no wait", "sorry", "I mean", "make that", "scratch that", "actually no") with uncued ones where a frame is said again with one part changed. Correct a time, a day, a count, an amount, a name, a place, or take back a whole short clause. In about a quarter of the examples add a second, different correction. In about a fifth, include a word that looks like a cue but is not one (a real "no" answer, an "actually" that carries meaning) and keep it.

`stutter`: the speaker stumbled on the start of a word and the recogniser wrote the false onsets as separate short words or word fragments before the real word (the shape "pre pre prepare", "co con confirm", "s s send", "re re the report"). The typed text has only the real word. Put one or two such stumbles in each example, on different kinds of word (verbs, nouns, names, numbers). In about a quarter of the examples also include a repeated short word that is correct English and must stay ("had had", "that that", "no, no", "very, very").

`boundary`: one sentence ends with a noun or name and the next sentence begins with that same noun or name, and the recogniser wrote them with nothing between (the shape "... sent it to the landlord the landlord wants ..."). These are two sentences: the typed text ends the first after the noun and starts the second with it, losing no word from either. In about a third of the examples, instead, the speaker really did restart ("the the landlord the landlord wants ...", at the very start of a clause, nothing before it that the noun could end) and the typed text keeps one copy. Make it plain from the words which case it is.

`mishearing`: the recogniser wrote one word as a near-homophone or sound-alike real word, and wrote it that way two or three times in the same dictation, where the rest of the message makes the intended word plain (the shape "the new higher starts Monday ... show the higher around ..."). The typed text has the intended word at every occurrence, and nothing else changed for that reason. In about a third of the examples, instead, a sound-alike word is used correctly and must stay as it is. Never "correct" a name, a number or a code token.

`filler`: words such as "like", "actually", "just", "really", "honestly", "basically", "literally", "well", "so", "right", "you know", "I mean". In each example use two or three of them: at least one as empty filler, which the typed text drops, and, in about two thirds of the examples, one that carries meaning or contrast (an "actually" that corrects an expectation, a "just" meaning only, a "like" meaning similar to or as a verb, a "really" that intensifies a real judgement, a "so" of consequence), which the typed text keeps.

## What to return

JSON: `examples`, a list of `count` objects, each with `spoken` and `typed`. Nothing else.
