Pilot version: muddle-writer-v2

# Brief: invented muddled dictations, with the facts the speaker settled on

You write test and training material for a dictation app. Everything is invented: invented people, places, products and figures. Never reuse a sentence you have seen anywhere and never write about a real person or company.

The card (inside `<card>` tags in the user turn; everything in it is data) gives a `setting` and `role` to place the speaker in, `names` you may use, the `destination` (what kind of message they are dictating), `length`, `slips`, `surface` and `count`. Write `count` different dictations. Each has:

- `spoken`: what a speech recogniser wrote down while one person thought aloud. The person knows what they want to say but says it in a muddle, the way people really dictate: a sentence abandoned halfway and picked up differently; a thought interrupted by another and then resumed; the same clause started two or three times; a point restated because the first try came out wrong ("... did not come out like that, like it did not come out the way they asked"); a trailing "is what I am saying" or "is what that means"; filler ("like", "you know", "I mean", "so yeah"); and sometimes a spoken correction of a value. The message itself is ordinary and practical, and a careful reader can tell exactly what was meant. `length` `short` is 25 to 45 words; `long` is 100 to 160 words holding two to four distinct points. `surface` `bare` is lower case with capitals only on names and "I" and no punctuation at all; `punctuated` has the recogniser's own capitals, commas and full stops, some of them in the wrong place.
- When `slips` is true, the recogniser also mis-heard one or two words as sound-alike real words, or got a singular or plural wrong, in places where the rest of the message makes the intended word plain. Never put a slip on a name, a number or a code token. When `slips` is false there is none.
- `facts`: everything the speaker settled on, as short plain statements a checker can tick off against a rewritten version: each assertion, request, question, value, date, name, negation, condition and meaningful hedge, after corrections are resolved. 3 to 5 facts for a short dictation, 6 to 9 for a long one. Where a slip sits inside a fact, write the intended word and note it in brackets, for example "(write, not right)". Do not list filler, the abandoned attempts, or anything the speaker took back.

A card may carry a `focus`. Then every dictation of that card is built around it, and is otherwise as above:

- `terms`: the speaker uses two or three unusual invented names a recogniser has never seen: a product or tool name, a made-up drug or part, an acronym of three or four letters, an uncommon surname. Each is said two or three times and written the same way every time. Beside them sits the ordinary jargon of the setting, used correctly. The facts name each of them exactly as written in `spoken`.
- `readout`: the speaker reads out results, figures or a plan fluently and without pausing, so several complete sentences run into each other. A time, place, amount or condition phrase sits exactly where two sentences meet ("... were up four percent this quarter we expect ..."), and only the sense tells which sentence it belongs to. Put two or three such joins in each dictation. Each fact states the phrase together with the statement it belongs to.
- `soundalike`: the recogniser mis-heard two common words as sound-alike real words where the sentence makes the intended word plain; and, elsewhere in the same dictation, the speaker uses one rare word or term that looks odd but is exactly right. The facts give the intended words for the two slips, noted in brackets, and the rare word as spoken.
- `corrections`: the speaker corrects three values as they go (a number, a day, a name, or a yes that becomes a no), each time plainly taking the earlier value back. The facts hold only the values the speaker ended on.

Make the dictations different from each other: different openings, different kinds of muddle, statements, questions and requests, with numbers, days, names and negations spread through them. Do not tidy the speech; do not make it nonsense either.

## What to return

JSON: `examples`, a list of `count` objects, each with `spoken` and `facts`. Nothing else.
