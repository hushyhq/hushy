"""Generation prompts for the CLI LLM (via `murmur-eval finetune llm`) and their parsers.

The LLM writes *content* (sentences with a correctable span, lists, casual messages) and a
small number of hand-to-template pairs (grammar repair, frame-switching corrections). Labels for
the bulk of the data come from `templates.py`, deterministically. Few-shot examples here are
our own; no dev-set sentence is ever put in a prompt.
"""

from __future__ import annotations

import json
import re
from typing import Any

DOMAINS = [
    "a software product team (bugs, releases, design reviews)",
    "sales and account management",
    "customer support replies",
    "clinic front-desk admin (appointments, forms; nothing clinical)",
    "teaching and school logistics",
    "family logistics and chores",
    "travel planning",
    "cooking, groceries and meal prep",
    "personal budgeting and bills",
    "party and event planning",
    "home repair and landlords",
    "fitness and sports practice",
    "paperwork, taxes and government forms",
    "marketing campaigns and social posts",
    "hiring, interviews and HR",
    "research, papers and lab work",
    "shipping, warehouses and logistics",
    "real estate viewings and rentals",
    "restaurant operations and staff shifts",
    "texting friends about plans",
    "dictating prompts to an AI coding assistant (files, functions, tests)",
    "emails to a client about a project",
    "an Indian-English speaker at work (natural phrasing like 'do the needful', 'prepone', 'revert')",
    "a startup founder talking about pricing and investors",
    "IT help desk and device setup",
    "gardening and pets",
    "a podcast or video production team",
    "legal and contract admin (non-advice)",
    "a remote team scheduling across time zones",
    "university students and group projects",
]

SENTENCES = """You are writing realistic dictation content for training a speech-cleanup model.
Domain: {domain}. Batch {batch}.

Write {count} different sentences a person might dictate, as they should finally be typed:
correct grammar, natural punctuation, 6 to 24 words, varied structure (requests, statements,
plans, questions, reminders). About half must contain a concrete detail: a number, time, day,
date, amount, person's name, place, product or quantity. Use diverse names (English, Indian,
Chinese, Hispanic, African, European). Do not use the words um, uh, like, basically, actually.

For each sentence also give:
- "subj": the grammatical subject phrase exactly as it begins the sentence (e.g. "The new
  dashboard"), or "" if the sentence does not start with its subject (questions, imperatives).
- "span": a short exact substring of the sentence (1-3 words) the speaker could plausibly
  correct mid-sentence: a number, time, day, name, place, item or adjective.
- "alt": a different value of the same kind that fits the sentence equally well.
- "kind": one of number, time, day, date, name, place, item, adjective, verb.

Return ONLY a JSON array, no prose, like:
[{{"s": "Can you move the budget review to Thursday at 3?", "subj": "", "span": "Thursday", "alt": "Friday", "kind": "day"}},
 {{"s": "The warehouse ships forty boxes to Pune every Monday.", "subj": "The warehouse", "span": "forty", "alt": "sixty", "kind": "number"}}]
"""

LISTS = """You are writing realistic dictation content for training a speech-cleanup model.
Domain: {domain}. Batch {batch}.

Write {count} different spoken enumerations. Each has a short lead-in phrase and 3 to 5 short
items (1 to 4 words each, noun phrases or short verb phrases, all the same grammatical kind).
Also pick one item the speaker could take back, and a short natural reason for dropping it that
refers to it with a pronoun ("we already have them", "it's broken", "she's out that week").

Return ONLY a JSON array, no prose, like:
[{{"lead": "For the camping trip we need", "items": ["the tent", "sleeping bags", "a lantern", "bug spray"], "drop": 2, "reason": "the cabin has lights already"}},
 {{"lead": "Agenda for Monday's sync", "items": ["hiring update", "Q3 targets", "the offsite"], "drop": 0, "reason": "we covered it last week"}}]
"drop" is the 0-based index of the item that can be dropped.
"""

GRAMMAR = """You are writing training pairs for a dictation cleanup model's "Polished" level,
which fixes spoken grammar while keeping the speaker's words, facts and tone.
Domain: {domain}. Batch {batch}. Focus: {focus}.

Write {count} pairs. "spoken" is what a person actually said (grammar slips typical of fast
speech, no filler words); "fixed" is the minimal correction: fix only the grammar, keep every
fact, name, number and negation, keep the same words wherever possible, do not formalize.
Mix short (8-15 words) and longer (16-40 words) pairs.

Focus types:
- agreement: "the invoices is late", "each of the vendors send", "she need"
- article: missing or wrong a/an/the ("attach invoice to email")
- tense: "last night we deploy the patch"
- hedge: a hedge spoken mid-clause ("the new banner also I think needs a darker color" -> "I think the new banner also needs a darker color")
- restart: the subject or clause restarted ("the new intern, the new intern starts on Monday")
- resumptive: a pronoun repeating the subject ("the scanner it jams on thick paper")
- dangling: an abandoned clause then the real one ("the migration can't, well the migration can start once backups finish")
- garbled: a self-interrupted, tangled sentence whose meaning is still clear
- runon: several clauses with no sentence breaks, to be split into sentences

Return ONLY a JSON array, no prose, like:
[{{"type": "agreement", "spoken": "The new filters is confusing and the users keeps asking about it.", "fixed": "The new filters are confusing and the users keep asking about them."}},
 {{"type": "hedge", "spoken": "This migration honestly I feel should wait until after the launch.", "fixed": "Honestly, I feel this migration should wait until after the launch."}}]
"""

CORRECTIONS = """You are writing training pairs for a dictation cleanup model. The speaker
corrects themselves mid-sentence; the cleaned text keeps only their final intent, placed in
the sentence frame they started with, and deletes only the abandoned words.
Domain: {domain}. Batch {batch}.

Write {count} pairs, spread across these patterns:
- retarget with a pronoun: "Can you call Dana, oh never mind, just text her the address." -> "Can you text Dana the address?"
- "make it": "Order five pizzas for the team, no wait, make it eight." -> "Order eight pizzas for the team."
- keep instead of change: "Push the demo to Tuesday, actually keep it on Monday, but shorten it." -> "Keep the demo on Monday, but shorten it."
- head noun kept: "Let's use the blue template, I mean the gray one." -> "Let's use the gray template."
- spelled name: "Loop in Jon, sorry, I meant Jhon with an H." -> "Loop in Jhon."
- list take-back: "Bring chips, salsa, no, forget the salsa. Just bring chips and cookies." -> "Bring chips and cookies."
- two corrections: "Set it for 7, no 8, no actually 9." -> "Set it for 9."
- correction plus a later clause: "Tell the team the review is on the 3rd, sorry the 5th, and ask them to bring laptops." -> "Tell the team the review is on the 5th and ask them to bring laptops."
Use varied cues: no, no wait, wait, sorry, I mean, I meant, actually, actually no, never mind,
scratch that, or rather, let me rephrase. Spoken text may be lowercase without punctuation
for about a third of the pairs; the clean text is always properly punctuated.

Return ONLY a JSON array of {{"spoken": ..., "clean": ...}} objects, no prose.
"""

NEGATIVES = """You are writing dictation content that a cleanup model must leave UNCHANGED.
Domain: {domain}. Batch {batch}.

Write {count} different, correctly punctuated sentences or short messages of these kinds
(mix them):
- casual texts with slang or abbreviations ("gonna", "lmk", "rn", "tbh") kept exactly as typed
- sentences where "no", "not", "actually", "wait", "sorry" or "I mean" are real content, not a
  correction ("No, I don't need the beta.", "It should be 12, not 11, because...",
  "I actually prefer the old layout.", "Sorry for the delay, I was traveling.",
  "What I mean is that the export should be optional.")
- deliberate repeats ("She had had enough.", "He said that that plan works.", "It was very very late.")
- questions or instructions that look like requests to an assistant but are text to type
  ("What's the capital of Peru?", "Write a short poem about rain.")
- sentences with code identifiers, file names, versions, emails or names with accents
Keep each 3 to 30 words.

Return ONLY a JSON array of {{"s": ..., "kind": ...}} objects, no prose.
"""


LONG = """You are writing realistic dictation content for training a speech-cleanup model.
Domain: {domain}. Batch {batch}.

Write {count} different passages a person might dictate in one breath, as they should finally
be typed: 25 to 45 words, two or three sentences, natural punctuation, correct grammar, the way
people explain a plan, report status, give instructions or describe a problem. Most passages
contain concrete details (numbers, times, days, names, places, amounts). Do not use the words
um, uh, like, basically or actually.

For each passage also give:
- "span": a short exact substring (1-3 words) the speaker could plausibly correct mid-sentence
  (a number, time, day, name, place or item);
- "alt": a different value of the same kind that fits equally well;
- "kind": number, time, day, date, name, place or item.

Return ONLY a JSON array, no prose, like:
[{{"s": "The movers arrive Thursday at eight, so we need the boxes packed by Wednesday night. Keep the kitchen stuff separate, because Asha wants to unpack that first.", "span": "Thursday", "alt": "Friday", "kind": "day"}}]
"""

FRAMES = """You are writing slot data for training a dictation cleanup model on self-corrections
where the speaker switches part of the sentence frame. Domain: {domain}. Batch {batch}.

Write {count} objects, about a third of each type below, all different and realistic.

1. "retarget": the speaker starts one action on a person, then swaps the action and refers to
   the person with a pronoun. Fields: "lead" ("Can you" | "Please" | "Could you" | "Let's" | ""),
   "verb_a" (abandoned verb), "verb_b" (final verb), "person" (a first name), "pronoun"
   ("him" | "her" | "them"), "rest" (what follows the pronoun, e.g. "the address" or "on Slack").
   Example: {{"type": "retarget", "lead": "Can you", "verb_a": "call", "verb_b": "text", "person": "Dana", "pronoun": "her", "rest": "the gate code"}}
2. "keep": the speaker starts to change a setting, then decides to keep the old value, and adds
   a clause. Fields: "verb_a" (e.g. "Move", "Push", "Change", "Bump"), "thing" (e.g. "the review"),
   "prep_a", "value_a" (the abandoned new value), "prep_b", "value_b" (the value kept),
   "tail" (a short clause starting with "but" or "and").
   Example: {{"type": "keep", "verb_a": "Push", "thing": "the vendor call", "prep_a": "to", "value_a": "Thursday", "prep_b": "on", "value_b": "Tuesday", "tail": "but invite the finance lead"}}
3. "headnoun": a sentence containing "the <adjective> <noun>" where the speaker corrects the
   adjective. Fields: "s" (the final, correct sentence, 7-20 words, using the corrected
   adjective), "adj_a" (abandoned adjective), "adj_b" (the adjective used in "s"), "noun"
   (plural or singular noun exactly as in "s").
   Example: {{"type": "headnoun", "s": "Order the black chairs for the lobby before Friday.", "adj_a": "gray", "adj_b": "black", "noun": "chairs"}}

Use diverse names (English, Indian, Chinese, Hispanic, African, European). Return ONLY a JSON
array, no prose.
"""

POLISHED_NEGATIVES = """You are writing dictation content that a grammar-polishing cleanup
model must leave UNCHANGED because it is already correct or deliberately casual.
Domain: {domain}. Batch {batch}.

Write {count} different sentences or short messages, correctly punctuated, 5 to 35 words,
mixing these kinds:
- grammar that looks wrong but is right ("None of the invoices were late.", "If I were you,
  I'd wait.", "The team are split on this.", "Neither option is great.", "Whom should I cc?")
- a hedge already at the front ("I think we can start without her.", "I guess the demo can wait.")
- casual or fragmentary notes a person would type as is ("Quick update: shipped.",
  "Running late, 10 min.", "gonna grab coffee, want one?")
- sentences with a list of two or three short items that should stay a sentence
  ("Bring the badge and the charger.")
- long but well-formed sentences with several clauses joined by "and", "but" or "because"
- technical text with identifiers, versions, paths or code terms
Do not use filler words or self-corrections.

Return ONLY a JSON array of {{"s": ..., "kind": ...}} objects, no prose.
"""

FRAME_NEGATIVES = """You are writing dictation content that a cleanup model must leave UNCHANGED even
though it contains words that often mark a self-correction ("no", "sorry", "actually", "just",
"leave it", "keep it", "the other one"). Domain: {domain}. Batch {batch}.

Write {count} different, correctly punctuated sentences, 6 to 25 words, where those words are
real content and nothing is being corrected. Mix these shapes (our own examples, do not reuse):
- "no" as an answer or a report: "I rang the vet twice, no reply, so I'll email instead."
- "no" to a person, then a separate request: "Tell the dog no, then give him the toy."
- "sorry" as an apology inside a request: "Hi Bea, sorry for the delay, just send the form when you can."
- "just" in a conditional follow-up: "Ask Tom if he can drive, and if not, just book a cab."
- a comparison of two options, both kept: "The old desk was fine, but honestly the new one is sturdier."
- "no luck" / "no answer" between two facts: "We tried the short cable, no luck, the long one reached."
- "actually" introducing a real observation: "I moved the lamp to the corner, actually, it lights the room better."
- "leave it" / "keep it" as the actual instruction: "Set the oven to 180 and leave it there for an hour."
- "the other one" / "the new one" as a normal reference, not a swap.

Return ONLY a JSON array of {{"s": ..., "shape": ...}} objects, no prose.
"""

AGREEMENT = """You are writing grammar data for a dictation cleanup model. Domain: {domain}. Batch {batch}.

Write {count} different, correct sentences, 8 to 22 words, each built like this:
- it starts with a subject noun phrase that begins with "The", "Our", "My" or "This"/"These";
- the next word is one of: is, are, was, were, has, have;
- later a pronoun refers back to the subject ("it" for singular, "they" for plural), followed by
  a present-tense verb (e.g. "it needs", "they need", "it runs", "they look").
About half singular, half plural.

For each give: "s" (the sentence), "subject" (the subject phrase exactly as it starts "s"),
"number" ("singular" or "plural"), "other" (the same subject phrase with the head noun in the
other number, e.g. "The invoice" -> "The invoices", "These servers" -> "This server").

Return ONLY a JSON array, no prose, like:
[{{"s": "The contract is ready and it needs one more signature.", "subject": "The contract", "number": "singular", "other": "The contracts"}},
 {{"s": "Our printers are jammed again and they need new rollers.", "subject": "Our printers", "number": "plural", "other": "Our printer"}}]
"""

TENSE = """You are writing grammar data for a dictation cleanup model. Domain: {domain}. Batch {batch}.

Write {count} different, correct past-tense sentences, 8 to 24 words, that each contain a time
marker ("yesterday", "last week", "on Monday", "this morning", "two days ago", ...) and two or
three regular past-tense verbs ending in "-ed" (e.g. "called", "fixed", "asked", "delivered",
"checked", "updated"; no irregular verbs like "went", "sent", "shipped" is fine).

Return ONLY a JSON array of {{"s": ...}} objects, no prose, like:
[{{"s": "Last Tuesday we updated the router and the office checked every laptop afterwards."}}]
"""

GARBLED = """You are writing training pairs for the "Polished" level of a dictation cleanup
model. Domain: {domain}. Batch {batch}.

Write {count} pairs. "spoken" is a sentence a person said while thinking aloud, garbled in one
or two of these ways: a hedge dropped mid-clause ("the new menu also I feel should ..."), a
clause started, abandoned with a dangling modal and restarted ("... because if we are calling X
free shouldn't, then Y should ..."), a subject said twice ("the invoice the invoice ..."), a
pronoun repeating the subject ("the scanner it ..."), missing articles, or a run-on joined by
"and" with no breaks. 15 to 40 words, no filler words (no um, uh, like).
"fixed" is what they meant: grammatical, split into sentences if it was a run-on, the hedge
moved to the front, the abandoned clause removed, keeping every fact, name, number, negation
and the speaker's own words wherever possible. Do not add information or formalize.

Return ONLY a JSON array of {{"spoken": ..., "fixed": ...}} objects, no prose.
"""

MEAN_NEGATIVES = """You are writing dictation content that a cleanup model must leave UNCHANGED even
though it contains "I mean", "rather", "make that", "or" or "sorry" — words that sometimes mark
a self-correction. Here they are real content. Domain: {domain}. Batch {batch}.

Write {count} different, correctly punctuated sentences, 5 to 25 words, mixing:
- "I mean" as emphasis or a clarification that adds content: "I mean it, the deadline is firm."
- "I mean" said at the very end as a softener: "The new chairs are comfortable, I mean."
- "rather" as preference or degree: "I'd rather take the early flight.", "It's rather cold in here."
- "make that" as a real instruction: "Make that call before lunch."
- "or" offering two real options: "We can meet Tuesday or Thursday, whichever suits you."
- "sorry" as a real apology followed by the request.
Our own examples above must not be reused. Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

CASUAL_NEGATIVES = """You are writing casual messages a person dictates to friends, exactly as they
would type them, which a cleanup model must leave UNCHANGED. Domain: {domain}. Batch {batch}.

Write {count} different messages, 4 to 20 words, in texting register: slang and abbreviations
("gonna", "wanna", "rn", "lol", "tbh", "u", "lmk", "ngl", "omg"), lower-case starts are fine.
Every message must use "like" the casual way people really do ("be there in like 5", "it was
like a whole thing", "she was like, no way", "like honestly") — here it is part of the voice,
not a filler to delete. No other filler words (no um, uh). Our examples must not be reused.

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

EXISTENTIAL = """You are writing grammar data for a dictation cleanup model. Domain: {domain}. Batch {batch}.

Write {count} different, correct sentences, 6 to 20 words, that each start with "There are",
"There were", "Here are" or "There have been", followed by a plural noun phrase with a number
or quantity ("two new bugs", "several complaints", "three people waiting").

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

NEGATION = """You are writing grammar data for a dictation cleanup model. Domain: {domain}. Batch {batch}.

Write {count} different, correct sentences, 6 to 22 words, each containing exactly one negation
written as a contraction followed later by one of: "any", "anything", "anyone", "anybody",
"anywhere", "ever" (e.g. "We don't have any spare chargers left.", "She hasn't told anyone yet.",
"I can't find it anywhere.").

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

MISS_SHAPES = [
    ("garbled-long",
     "a long (25-45 words) self-interrupted sentence: a hedge dropped mid-clause, a clause abandoned "
     "with a dangling negated modal (\"shouldn't,\" / \"won't,\") and restarted, the subject said twice. "
     "The fix is one or two clean sentences that keep every claim and condition",
     "spoken: \"The export button also I feel should be on the toolbar because if we are putting print on "
     "the toolbar wouldn't, the export button should obviously sit next to it\" -> fixed: \"I feel the export "
     "button should also be on the toolbar. If we are putting print on the toolbar, the export button "
     "should obviously sit next to it.\""),
    ("nested-repeat",
     "a sentence with a word cut off and restarted (\"in the s in the\"), a phrase repeated right after "
     "itself (\"it's a it's a\"), and a quoted or restated thought introduced by \"should have been\" / "
     "\"what I wanted was\" that needs a colon",
     "spoken: \"Like in the s in the second slide, what I wanted was it says it's a it's a draft not a final "
     "version\" -> fixed: \"Like in the second slide, what I wanted was: it says it's a draft, not a final "
     "version.\""),
    ("modal-mean",
     "a dangling modal abandoned and restated with a clarifying \"I mean\" or \"I guess\" "
     "(\"We can't, I mean we can ship it if QA signs off\"); the fix keeps only the restated clause",
     "spoken: \"They couldn't, I mean they could finish it by Friday with one more tester\" -> fixed: "
     "\"They could finish it by Friday with one more tester.\""),
    ("article-choice",
     "a request or statement missing articles where the first mention needs \"a\"/\"an\" and a known "
     "thing needs \"the\" (\"attach receipt to expense report\")",
     "spoken: \"Please add note to invoice before you send it to accountant\" -> fixed: \"Please add a "
     "note to the invoice before you send it to the accountant.\""),
    ("parallel",
     "a comparison or either/or spoken with broken parallel structure and a stray question mark "
     "(\"whether it is like a short call or is it like a full meeting?\")",
     "spoken: \"It depends whether it is a quick fix or is it a full rewrite? I can't tell yet\" -> "
     "fixed: \"It depends whether it's a quick fix or a full rewrite. I can't tell yet.\""),
]

GARBLED_MISS = """You are writing training pairs for the "Polished" level of a dictation cleanup
model. Domain: {domain}. Batch {batch}. Shape: {focus}.

Write {count} different pairs of this shape. "spoken" is what a person actually said, thinking
aloud (no filler words like um/uh). "fixed" is what they meant: grammatical, keeping every fact,
name, number, negation and the speaker's own words wherever possible; never add information,
never summarize, never formalize casual wording. Vary the topics, sentence lengths and names;
do not reuse the example.

Example of the shape (ours; do not copy): {example}

Return ONLY a JSON array of {{"spoken": ..., "fixed": ...}} objects, no prose.
"""

MODAL_SEEDS = """You are writing dictation content for a cleanup model. Domain: {domain}. Batch {batch}.

Write {count} different, correct sentences, 8 to 24 words. Each must START with a subject
("The new banner", "Our landlord", "The quarterly report", "We", "They", "This contract", ...)
immediately followed by one of the modal verbs "should", "could", "would", "can" or "will", then
the rest of the sentence (e.g. "The quarterly report should include the churn numbers from March.").
About half should add a reason or condition with "because" or "if".

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

GRAMMAR_FOCI = [
    "agreement and article",
    "tense and agreement",
    "hedge and restart",
    "resumptive and dangling",
    "garbled and runon",
    "runon and agreement",
    "article and hedge",
    "restart and garbled",
]


# v5.4: negative robustness. The v5.3 2B kept 100% of the dev negatives but only 87–93% on the
# blind held-out set: it had learned *our* negatives. These banks widen what "already fine" looks
# like: every register, length and style a person dictates.
REGISTERS = [
    ("formal-email", "sentences from formal work emails: openings, requests, polite hedges, scheduling, sign-offs"),
    ("technical", "engineering talk with file paths, flags, version numbers, API and function names, error messages, commands"),
    ("names-numbers", "messages dense with people's names, companies, places, prices, dates, times, quantities and percentages"),
    ("casual-text", "texts to friends and family: fragments, slang, abbreviations, lower-case starts, jokes"),
    ("meeting-notes", "terse notes and action items someone dictates during or after a meeting"),
    ("support-reply", "customer-support replies: apologetic, precise, step-by-step, with order or ticket numbers"),
    ("clinical", "clinical or care notes: doses, symptoms, times, abbreviations like BP or PRN"),
    ("legal-admin", "contract, policy or paperwork language: clauses, defined terms, dates, amounts"),
    ("academic", "study notes and academic writing: citations spoken inline, careful hedged claims"),
    ("social-post", "social-media posts and captions: exclamations, hashtags spoken as words, emphasis"),
    ("instructions", "recipes, how-to steps and directions written as full sentences, including inline lists"),
    ("quotes", "reported speech and quotations: someone said '...', titles of books, songs or error messages in quotes"),
    ("code-ish", "dictated code-adjacent text: 'set max retries to 5 in config dot yaml', variable names, shell commands"),
    ("parenting-school", "messages about kids, school, pick-ups, teachers, permission slips, activities"),
    ("long-form", "long well-formed sentences of 30 to 60 words with several clauses, as people dictate paragraphs"),
]

REGISTER_NEGATIVES = """You are writing dictation content that a speech-cleanup model must leave UNCHANGED
because it is already acceptable exactly as the person said it. Register: {register_description}.
Domain: {domain}. Batch {batch}.

Write {count} different texts in that register. Mix lengths on purpose: about a third short
(3 to 9 words), half medium (10 to 30 words), the rest long (31 to 60 words). Vary the style:
some fully punctuated, some written the way a person types quickly. Each must be something a
careful editor would accept as-is: no filler words (um, uh), no stutters, no self-corrections, no
grammar mistakes. Deliberately casual or terse writing is fine when it suits the register.
Use your own content; do not reuse any example sentence.

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

TEMPTING_NEGATIVES = """You are writing dictation content that a grammar-polishing cleanup model must leave
UNCHANGED, even though a fluent editor might be *tempted* to rephrase it. Domain: {domain}. Batch {batch}.

Write {count} different sentences, 5 to 40 words, each acceptable as dictated. Mix these kinds:
- starting with "And", "But", "So" or "Because" as people naturally do
- ending with a preposition, a split infinitive, or "try and"
- deliberate repetition for emphasis ("really, really good"), or rhetorical questions
- passive voice, long sentences joined by commas and "and", or a colon introducing a clause
- hedges and softeners that carry meaning ("I think", "maybe", "sort of", "honestly", "to be fair")
- informal but correct usage ("who" in questions, "less" with amounts, "data is", "they" for one person)
- words that look like fillers or corrections but are content ("like" as a verb or comparison,
  "actually" meaning "in fact", "no" as an answer, "I mean" meaning "I intend", "well" as an adverb)
Nothing may need a real fix. Use your own content.

Return ONLY a JSON array of {{"s": ..., "kind": ...}} objects, no prose.
"""


# v5.5: the v5.4 2B kept a filler "actually" and stopped splitting "and … and … because" run-ons.
RUNON_CHAINS = """You are writing training pairs for the "Polished" level of a dictation cleanup
model. Domain: {domain}. Batch {batch}.

Write {count} pairs. "spoken" is one breathless run-on a person dictated: three to five clauses
chained with "and", "and then", "so" or "because", 25 to 55 words, lower case, no punctuation, no
filler words. "fixed" is the same text split into two to four grammatical sentences with
punctuation and capitals. Keep every word, name, number and negation; the only words you may
drop are the "and"/"and then" that now fall at a sentence break. Keep "because" and "so" where
they carry the reason. Do not add, reorder or formalize anything.

Return ONLY a JSON array of {{"spoken": ..., "fixed": ...}} objects, no prose.
"""

MEANING_DISCOURSE = """You are writing dictation content that a cleanup model must leave UNCHANGED.
Domain: {domain}. Batch {batch}.

Write {count} different sentences, 6 to 30 words, correctly punctuated, where "actually",
"sort of", "kind of" or "honestly" CARRIES MEANING and removing it would change what the speaker
says. Mix these uses:
- "actually" contradicting an expectation ("I assumed it was Tuesday, but the demo is actually on
  Wednesday.")
- "sort of" or "kind of" meaning roughly or partly ("The patch sort of fixes it; the crash is rarer.")
- "honestly" as a claim of sincerity the sentence depends on ("I honestly didn't know the budget
  was cut.")
Use the word once, mid-sentence, never as the first word. Use your own content.

Return ONLY a JSON array of {{"s": ...}} objects, no prose.
"""

TECH_REGISTERS = [r for r in REGISTERS if r[0] in {"technical", "code-ish", "names-numbers"}]


def extract_json_array(text: str) -> list[Any]:
    """The first top-level JSON array in `text` (LLMs sometimes wrap it in prose or fences)."""
    text = re.sub(r"```(?:json)?", "", text)
    start = text.find("[")
    while start != -1:
        depth = 0
        in_string = False
        escape = False
        for index in range(start, len(text)):
            char = text[index]
            if in_string:
                if escape:
                    escape = False
                elif char == "\\":
                    escape = True
                elif char == '"':
                    in_string = False
                continue
            if char == '"':
                in_string = True
            elif char == "[":
                depth += 1
            elif char == "]":
                depth -= 1
                if depth == 0:
                    try:
                        value = json.loads(text[start : index + 1])
                    except json.JSONDecodeError:
                        break
                    return value if isinstance(value, list) else []
        start = text.find("[", start + 1)
    return []


def build_prompts(plan: dict[str, int]) -> list[dict[str, str]]:
    """Prompt rows for `murmur-eval finetune llm`: plan maps kind -> number of calls."""
    templates = {
        "sentences": (SENTENCES, 40),
        "lists": (LISTS, 25),
        "grammar": (GRAMMAR, 25),
        "corrections": (CORRECTIONS, 25),
        "negatives": (NEGATIVES, 40),
        "long": (LONG, 14),
        "frames": (FRAMES, 30),
        "polishedneg": (POLISHED_NEGATIVES, 40),
        "frameneg": (FRAME_NEGATIVES, 30),
        "agreement": (AGREEMENT, 30),
        "tense": (TENSE, 30),
        "garbled": (GARBLED, 20),
        "meanneg": (MEAN_NEGATIVES, 40),
        "casualneg": (CASUAL_NEGATIVES, 40),
        "existential": (EXISTENTIAL, 30),
        "negation": (NEGATION, 30),
        "garbledmiss": (GARBLED_MISS, 20),
        "modalseed": (MODAL_SEEDS, 40),
        "registerneg": (REGISTER_NEGATIVES, 30),
        "temptingneg": (TEMPTING_NEGATIVES, 30),
        "runonchain": (RUNON_CHAINS, 20),
        "meaningneg": (MEANING_DISCOURSE, 30),
        "techneg": (REGISTER_NEGATIVES, 30),
    }
    rows = []
    for kind, calls in plan.items():
        template, count = templates[kind]
        for batch in range(calls):
            domain = DOMAINS[(batch * 7 + len(kind)) % len(DOMAINS)]
            focus = GRAMMAR_FOCI[batch % len(GRAMMAR_FOCI)]
            if kind in ("registerneg", "techneg"):
                bank = REGISTERS if kind == "registerneg" else TECH_REGISTERS
                register, description = bank[batch % len(bank)]
                prompt = template.format(domain=domain, batch=batch + 1, count=count, register_description=description)
                rows.append({"id": f"{kind}-{batch:03d}", "kind": kind, "domain": domain, "shape": register, "prompt": prompt})
                continue
            if kind == "garbledmiss":
                shape, description, example = MISS_SHAPES[batch % len(MISS_SHAPES)]
                prompt = template.format(domain=domain, batch=batch + 1, count=count, focus=description, example=example)
                rows.append({"id": f"{kind}-{batch:03d}", "kind": kind, "domain": domain, "shape": shape, "prompt": prompt})
                continue
            prompt = template.format(domain=domain, batch=batch + 1, count=count, focus=focus)
            rows.append({"id": f"{kind}-{batch:03d}", "kind": kind, "domain": domain, "prompt": prompt})
    return rows
