# Paste matrix

What Hushy's delivery code does for 30 Mac apps when the paste lands or is lost, and when its field
can or cannot be read. It answers gap 6 in `docs/research/nov7/feature-gaps.md` ("never lose a take or
a paste") and the paste-matrix item of gate 9 in `docs/product/DIRECTION.md`.

## What this is, and what it is not

**It is a model run through the real code.** No app was launched. Each app is placed in the accessibility
surface its toolkit is known for (the "Surface" column). The surface's key-down facts (role, settable
value, selected-text range) go through the real `FocusAnswer.classify`. A scripted field then goes through
the real `TargetedDelivery`, `LandingEvidence` and `FieldPasteWatch`, with the same fake clipboard the
delivery tests use. The test `PasteMatrixTests` fails when the committed table stops matching what the
code does.

**It is not an observation of those apps.** The one modelled fact is the placement of each app in a
surface, and the "Field reads" column (whether a count or caret read of the field is expected to work).
Both come from how the toolkits are built, not from reading the apps. Nobody has run these 30 apps on a
Mac for this table. Treat the surface placement as a hypothesis, and the outcome columns as exact for that
hypothesis. Apps that share a surface share a row of outcomes, because delivery sees only the answer and
the field, never the app.

## How to read it

The four outcome columns are the four things a paste can do. `lands` or `lost` is whether the text
reached the field. `reads` or `unreadable` is whether Hushy could read the field's count and caret.

| Code | Meaning | Where the words are |
|---|---|---|
| C | The field showed the paste (count changed, or the caret moved by the pasted length). | In the field. The earlier clipboard comes back. |
| D | The paste was lost and Hushy saw it. The card opens. | Clipboard, card and History (listed as not pasted). |
| K | The paste could not be read back. A quiet "Pasted" row says so. | Clipboard (kept) and History. |
| H | Reported as pasted and never checked. | The earlier clipboard comes back. The words are in History and behind ⌃⌘V and ⌃⌘C. |

Two facts the table shows:

- **No lost paste is ever shown as confirmed** (`testNoScenarioEverConfirmsAPasteThatDidNotLand`).
- **The only way a lost paste leaves the words in History alone is `H`**: an app whose key-down answer is
  `field` and whose field either cannot be read, or is not watched. Eleven of the 30 apps are modelled that
  way. The second look is an allowlist (`FieldWatch.watchedApps`): TextEdit, Notes and Mail, three Apple text
  views whose count follows a paste and whose Return adds a line, so a person who presses Return before the
  first read cannot turn a landed paste into an unchanged field. Every other app is unwatched, and `H` is the
  honest answer for those whose key-down answer is `field`:
  - Safari and any browser: any page may draw its own editor behind a hidden input. Browsers not on a list
    (Dia, ChatGPT Atlas, Comet, Chromium, Orion, DuckDuckGo, SigmaOS, LibreWolf) fall here by default.
  - VS Code and Cursor: the helper textarea behind xterm.js and Monaco's input area report a text area that
    stays empty whether or not the paste landed.
  - Messages, WhatsApp, Telegram: Return sends and empties the composer, so a landed paste followed by the
    person's Return reads 0 then 0, the picture of a lost paste.
  - Xcode: its assistant composer is the same case.
  - Terminal: the agent composers inside it (Claude Code, Codex) may keep the same character count after a
    paste. Unproven either way, so unwatched. iTerm2 and Ghostty do not even answer `field`.
  The uncertain targets (`unknown`) keep the words on the clipboard whenever they cannot tell.
  `testEveryCombinationEndsConfirmedOnTheClipboardHeldOrNamedHistoryOnly` runs 96 combinations of
  answer, field, password field, moved focus and a failed paste key, and fails if any other combination
  ends with the words in History alone. `testAnElectronTextAreaBehindAHiddenInputIsNeverCalledLost`,
  `testABrowserPageIsNotWatchedEvenWhenItsFieldReads` and
  `testOnlyTheAllowlistedAppsAreWatchedAndTheRestNeverRaiseTheAlarm` pin the unwatched cases.

## Not covered

- Real apps. The first column of the table that would matter, the observed `focus=` and landing result per
  app, comes from the app's own log (`paste-diagnosis` lines carry the app, its category, the element seen
  and timings, never text). Replace a surface placement with the observed one when a line disagrees.
- Pastes with Return, multi-line text and bracketed paste in terminals.
- Latency. A watched field (TextEdit, Notes, Mail) is read once at key-down, one bounded read; nothing is read before ⌘V. Its cost on a real Mac is not measured here.
- Whether any real app behaves like the hidden-input text area. The placement of VS Code and Cursor there is the reviewer's report of how xterm.js and Monaco appear to Accessibility, not an observation.
- Five-minute takes, a clipped last word and a crash. See `NEVER-LOSE-A-TAKE.md`.

## Regenerate

```
HUSHY_WRITE_PASTE_MATRIX=1 scripts/mac-heavy.sh paste-matrix swift test --filter PasteMatrixTests
```

Read the diff before committing it: a changed cell is a changed behaviour.

## The table

<!-- paste-matrix:start -->
| App | Category | Surface (modelled) | Key-down answer | Field reads | lands, reads | lands, unreadable | lost, reads | lost, unreadable |
|---|---|---|---|---|---|---|---|---|
| Google Chrome | Other | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Safari | Other | WebKit text input | field | yes | H | H | H | H |
| Slack | Work messages | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Notes | Documents | AppKit text view | field | yes | C | H | D | H |
| Mail | Email | WebKit text input | field | yes | C | H | D | H |
| Messages | Personal messages | AppKit text view | field | yes | H | H | H | H |
| Microsoft Outlook | Email | Custom-drawn text editor | unknown | no | C | K | D | K |
| Microsoft Word | Documents | Custom-drawn text editor | unknown | no | C | K | D | K |
| Microsoft Teams | Work messages | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Zoom chat | Work messages | Custom-drawn text editor | unknown | no | C | K | D | K |
| Discord | Personal messages | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| WhatsApp | Personal messages | AppKit text view | field | yes | H | H | H | H |
| Telegram | Personal messages | AppKit text view | field | yes | H | H | H | H |
| Notion | Documents | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Obsidian | Documents | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Linear | Work messages | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Figma | Other | Canvas app with web text | unknown | no | C | K | D | K |
| Visual Studio Code | Code | Electron text area behind a hidden input | field | yes, but it stays empty | H | H | H | H |
| Cursor | Code | Electron text area behind a hidden input | field | yes, but it stays empty | H | H | H | H |
| Xcode | Code | AppKit text view | field | yes | H | H | H | H |
| Terminal | Code | Terminal text area | field | yes | H | H | H | H |
| iTerm2 | Code | GPU-drawn terminal | unknown | no | C | K | D | K |
| Ghostty | Code | GPU-drawn terminal | unknown | no | C | K | D | K |
| Warp | Code | GPU-drawn terminal | unknown | no | C | K | D | K |
| Claude desktop | AI prompts | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| ChatGPT desktop | AI prompts | Custom-drawn text editor | unknown | no | C | K | D | K |
| Pages | Documents | Custom-drawn text editor | unknown | no | C | K | D | K |
| TextEdit | Documents | AppKit text view | field | yes | C | H | D | H |
| Arc | Other | Chromium or Electron web content | unknown | sometimes | C | K | D | K |
| Firefox | Other | Gecko web content | unknown | sometimes | C | K | D | K |
<!-- paste-matrix:end -->
