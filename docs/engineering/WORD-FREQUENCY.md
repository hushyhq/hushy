# Word-frequency table (graded lexicon)

2026-10-28. Algorithms audit item 5 / 1b (`docs/research/algorithms-audit-2026-10-26.md`); the maintainers approved shipping a 1 to 2 MB
frequency table with an attribution line on 28 Oct.

## What it is

`WordFrequency` (`Sources/MurmurCore/Lexicon/WordFrequency.swift`) answers "how common is this word in written English" as a
Zipf grade (log10 of occurrences per billion words; "the" 7.5, "email" 5.25, "podcast" 4.25, a name or brand under 2.5,
unknown 0, in steps of a quarter). It replaces the system dictionary (`/usr/share/dict/words`, loaded into two `Set`s of 210,000
and 234,000 words) as the "is this an ordinary word?" test in the boost guards (`BoostGuard.filter` through
`VocabularyContext.guarded`, `DraftCommonWordGuard`, `ScreenBoostPolicy`, `InstalledNamePolicy`, `ContextWidening`,
`ContextAwareness`, `InstalledNameFixer`, `DictionaryTermFixer`, `TermRecall`), the learner (`LearningLexicon.isCommonWord`:
`CorrectionClassifier`, `Learner`) and the drift guard (`AsrDriftGuard`). Two lines on the grade:

| Line | Value | Meaning |
|---|---|---|
| `ordinaryThreshold` | 2.5 | An ordinary word: not boosted over, never learned as a name. 1 or 2 letters need `shortOrdinaryThreshold` 5.5 (the table is full of abbreviations: "vs", "pm", "tv"; every real two-letter word grades 5.75 or more). |
| `knownThreshold` | 1.75 | English at all, however rare: what the drift guard counts as a known word. |

Not changed: the cleanup path (`SmartCleaner`, `SpokenWordFidelity`, `WordRelation`, `CorrectionBound`, `SpokenTrackerTokens`) and
`NameOfferChoice` still use `BoostGuard.systemWords`. They ask a different question ("is this a dictionary word in any
capitals", rare words included), and the cleanup gate must not move.

## Source and licence

| | |
|---|---|
| Source | C4, English (`allenai/c4`, `en/c4-train.00000-of-01024.json.gz` and `en/c4-train.00512-of-01024.json.gz`; 356,317 documents each, 249,038,464 word tokens in all) |
| Licence | Open Data Commons Attribution License (ODC-By) 1.0 (dataset card, `license: odc-by`). The text is Common Crawl web text, subject to the Common Crawl terms of use. We ship counts-derived grades only, no text. |
| Download | `Evals/runs/public/c4-wordfreq/` (git-ignored); SHA-256 of the two shards: `8ef8d75b0e045dec4aa5123a671b4564466b0707086a7ed1ba8721626dfffbc9` and `e9333c6f73c30c9cb7f31794025eb9129455fac2edd64f8b3f22f879124c6a85`; 319 MB each. |
| Attribution | `Resources/Licenses/WordFrequency-NOTICE.txt`, copied into the app's `Contents/Resources/Licenses/` by `scripts/build-app.sh` (it copies every `*.txt` there); this page. |

Options looked at and not used: `wordfreq` (Robyn Speer; data CC BY-SA 4.0 and several of its inputs have their own terms; the
project is no longer updated), SUBTLEX (research licence), Google Books n-grams (CC BY 3.0 but hundreds of GB for one
column), Norvig's `count_1w.txt` (derived from the Google Web 1T corpus; the licence note is unclear). Share-alike data in a
shipped binary is the question the founder has not answered, so a table we compute from an attribution-only corpus is the
simplest thing that is clearly allowed. Newer or larger shards can be added by re-running the two scripts.

## How it was made (repeat with the scripts)

```bash
python3 -I scripts/wordfreq/count_words.py counts-00000.json c4-train.00000-of-01024.json.gz
python3 -I scripts/wordfreq/count_words.py counts-00512.json c4-train.00512-of-01024.json.gz
python3 -I scripts/wordfreq/build_table.py counts-00000.json counts-00512.json Sources/MurmurCore/Lexicon/WordFrequencyData.swift --min-zipf 1.5 --stats
```

- Counted: word tokens made only of letters and inner apostrophes, with no digit, slash, at-sign, hyphen or underscore touching them and
  no dot followed by a letter (so URLs, addresses, file names and hyphenated words are not counted).
- Only **lowercase** occurrences count, so a name written almost always with a capital ("sarah", "june") scores low and an ordinary
  word ("will", "mark", "grace") scores high. A form that is capitalized in the middle of a sentence more often than it appears in
  lowercase is cut by the square of the lowercase share (`adjusted` in `build_table.py`).
- Kept from Zipf 1.5 (86,851 forms), graded A to Z in steps of 0.25.
- Stored as one string in the binary: each entry is the word, then its grade letter, sorted by word; nothing is parsed or copied. The first
  lookup finds where each entry starts (0.8 ms in a release build), every lookup is a binary search. Inflections ("voices", "invited",
  "stopped", "quickly") also try their stem, with the same rules the dictionary check used.

## Measured (`murmur-eval lexicon`, release build, invented lists in `Evals/lexicon-b3a.json`)

The audit's own B3a/B4 lists were not kept; these are rebuilt with the same classes (47 plain modern words, 50 names, brands and products
including ones that are also dictionary words, 10 rare dictionary words, 25 everyday short dictations for the drift guard).

| Test | System dictionary | Word-frequency table |
|---|---|---|
| Everyday modern words counted "not ordinary" (47) | 39 | **0** |
| Names, brands and products counted "ordinary" (50) | 21 | **16** |
| Rare dictionary words counted "ordinary" (10) | 8 | **0** |
| Everyday short dictations sent to the second recogniser as drift (25) | 2 ("Email Priya today.", "Download the podcast.") | **0** |
| First use | 48 ms per set, two sets in the app (file read and set) | 0.8 ms unloaded, 2.6 ms under load (index only) |
| One `isOrdinary` lookup, mixed words and inflections | 101 ns | 528 ns |
| Memory added | 27 MB per set | 1.2 MB (the table is 783 KB in the binary) |

On the audit's own lists the dictionary scored 33/47 and 35/50; these lists differ, the failure is the same. Where it matters downstream:

| Gate | Before | After |
|---|---|---|
| `murmur-eval learn` (suggest-only and auto-activate) | 11/11 learnable terms, mean 1.55 fixes, false learns 0/17; short dictations 10/11, mean 2.20, 0/19 | the same; and "Anthropic" (the known limit, an ordinary dictionary word) is now learned after 2 fixes: follow-up term accuracy 86.1% to 94.4%, WER 1.5% to 0.8% |
| `murmur-eval common-words` (20 cases) | exact 20/20, 2 boost-stage losses | the same |
| Cleanup gate (`scripts/gate-cleanup.sh`, intent 2B): public 300, golden, never, probe, misheard, long+live | public exact 232; 0 changed texts | public exact 232; **0 changed texts**; made-worse unchanged at every step (model 67 to 67 and 8 to 8; boost, fixers, checks 0 to 0) |
| Vocabulary boost on invented speech (record only) | harm rows made worse at the boost 39/201, after the guard 0; win after guard 64/97 | 37/201 and 0; win after the guard **68/97** (after boost 73 to 72, recogniser 46 to 46) |


The 16 names that stay "ordinary" are real words as well (notion, linear, slack, cursor, swift, grace, mark, will, stripe, zoom, arc, loom,
llama, obsidian) or brands people write in lowercase (nginx, whatsapp). A frequency cannot tell "Mark" the name from "mark" the verb; that
needs the position and the app, which is the arbiter's job (audit item 1d), and the grade now gives it a number to weigh.

## Known limits

- A snapshot of web English from the 2019 crawl: newer products ("claude", "openai", "supabase") score 0, which is what we want for
  names, and newer words ("rizz") are missing until a refresh. Refresh: run the two scripts on another shard.
- Words with a grade from 1.75 to 2.5 are "known" but not "ordinary": a rare real word ("abdicate", Zipf 2.25) is no longer protected from a boost.
  The cleanup path keeps the dictionary, which is where such protection mattered.
- English only, as before.
