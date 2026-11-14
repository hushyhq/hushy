# Evaluation

The evaluation harness is `murmur-eval` (`Sources/murmur-eval`). Run `swift run murmur-eval` for
every command. Scorers and judges for the Python side are in `scripts/` (`*_score.py`,
`api_judge*.py`, `llm-judge.py`).

## What is in this folder

| Path | What it is |
|---|---|
| `demo/` | Small invented demo sets, written for this repository. They show the file format and let a runner start. They are too small to compare models. |
| `finetune-prompts/` | The system prompts the models are trained and evaluated with. |
| `judge/` | Rubrics and instructions for the model judges. |
| `tools-v1.schema.json` | The voice-action tool schema the action evals compare against. |
| `meeting-extract/LICENSES.md` | Licence of every corpus the meeting-extract recipe uses. |

The maintainers' development, held-out and sealed sets are not published. Some are built from real
dictations, and the sealed sets must stay unseen to stay useful. Results from sealed sets are
published only as totals. Runners that default to one of those files need an explicit path here,
for example:

```bash
swift run murmur-eval cleanup --golden Evals/demo/dictation-demo.json --backend none
```

`--backend none` runs the rule-based cleaner. `--backend apple` uses Apple's on-device model
(macOS 26 with Apple Intelligence), and `--backend mlx --mlx-model <dir>` a local MLX model.

## Public benchmarks

Invented sets share their authors' blind spots, so score on public sets as well.
`murmur-eval download <name>` fetches a public benchmark from its own host into `Evals/data/`
(git-ignored); with no name it downloads the default ones. The names are in
`Sources/murmur-eval/Datasets.swift`. Among them: LibriSpeech, AMI
(headset and far-field), Earnings-22, EdAcc, FLEURS, MLS, People's Speech, and the Open ASR
Leaderboard sets. Each keeps its own licence. Nothing is mirrored here.

## The demo set format

`demo/dictation-demo.json` is a list of cases:

| Field | Meaning |
|---|---|
| `id` | Unique id |
| `tag` | What the case tests |
| `spoken` | The recogniser's text, as it would arrive |
| `expected` | The text a person would have typed |
| `alternatives` | Optional other acceptable outputs |
