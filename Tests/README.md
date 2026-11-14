# Tests

`swift test` runs the MurmurCore suites (Swift Testing):

| Suite | Covers |
|---|---|
| TextCleaner | self-corrections, literal "no", scratch that, line breaks, fillers, lists, press enter, verbatim |
| Personalizer | dictionary spellings, snippets, validation |
| Store | dictations, notes, FTS search, retention |
| Insights / Edit verdict | totals, streaks, categories, edit-free rate |
| MCPServer | initialize, tools/list, tool calls, error handling |
| Agent stream parsing / fixtures / chat bridge | Claude Code stream-json parsing (canned lines and real redacted captures under `Fixtures/ClaudeStream`), reply folding, tool policy, fake-agent subprocess path |
| Live Claude Code round trip | opt-in (`HUSHY_LIVE_CLAUDE=1`): the real CLI + `hushy-mcp` against a seeded temp data directory; skipped by default |
| Summaries and export | extractive summaries, Markdown export |
| Eval metrics | WER, list-format matching, inline bullets, model hints |
| Writing styles | every style, email layout, words never change, code never styled |
| App integration | Style-page apps classify into their own context; browser web apps |
| Onboarding funnel / download progress | first-occurrence-wins timestamps, time to first dictation, bytes/percent/ETA formatting, sliding-window rate estimate |
| Update feed configuration (MurmurTests) | Sparkle placeholders/blank/http/short-key all mean "updates aren't configured" |

App-level behaviour (audio, hotkeys, paste) is verified with `murmur-eval` (which drives the same
capture/cleanup code paths) and with `--snapshots` for UI.
