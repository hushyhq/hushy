# murmur-mcp

Read-only [Model Context Protocol](https://modelcontextprotocol.io) server over stdio. The Swift
target keeps the codename `murmur-mcp`, but `scripts/build-app.sh` ships
the built binary as `Hushy.app/Contents/MacOS/hushy-mcp` — that on-disk filename is what AI
clients launch as a subprocess and what macOS attributes TCC/permission prompts to, so it was
renamed even though the Swift target name was not. It opens the Hushy database read-only and
never opens a network port.

It fails closed. A client launched with no flag (every installed entry) gets one tool, `get_insights`
(usage totals, no personal text). Hushy's own Assistant launches it with `--scope notes` and gets
`search_notes`, `list_notes`, `get_note`, `meeting_memory`, `meeting_commitments`, `meeting_rows` (meetings
flag) and `propose_action`, which only validates a
proposal and returns "awaiting the user's confirmation in Hushy" because the Assistant shows that card.
The dictation-history tools (`search_history`, `recent_dictations`) and the connected `propose_*`
tools no longer exist; a call to one returns an error that says so and that nothing was done.
Logic lives in `MurmurCore/MCP/MCPServer.swift` (unit-tested); this target is only the stdio loop.

Try it by hand:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}' \
  | build/Hushy.app/Contents/MacOS/hushy-mcp
```

Connect a client from the app (Ask your AI page) or manually:
`claude mcp add --scope user hushy -- "/path/to/Hushy.app/Contents/MacOS/hushy-mcp"`.
