import Foundation

/// Builds throwaway fake `claude`/`codex` executables for testing `ClaudeCLIJudge` /
/// `CodexCLIJudge` end to end without ever invoking the real CLIs. Each fake is a small shell
/// script (`#!/bin/sh`), made executable, that:
///   - records the argv it was invoked with (one per line) to `argvLogPath`, so tests can assert
///     the exact flags used and that the prompt never appears as an argument;
///   - reads stdin fully and records it to `stdinLogPath`, so tests can assert the prompt went
///     via stdin;
///   - emits a scripted response.
///
/// These are real subprocesses launched via `Process`/argv, exactly like the production code
/// path — the "fake" is only in what CLI binary sits at the other end, not in how it's invoked.
enum CLIJudgeFakeScripts {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fake `claude -p ... --output-format json` that logs argv/stdin and prints a
    /// `{"result": "<jsonText>"}` envelope, mirroring the real CLI's `--output-format json`
    /// shape. `resultText` is delivered base64-encoded and decoded with `base64 -D` inside the
    /// script (then JSON-encoded via a tiny embedded Python call) so arbitrary quotes/braces in
    /// `resultText` never have to survive shell quoting rules.
    static func makeFakeClaude(in dir: URL, resultText: String) throws -> URL {
        let scriptPath = dir.appendingPathComponent("fake-claude")
        let argvLog = dir.appendingPathComponent("argv.log").path
        let stdinLog = dir.appendingPathComponent("stdin.log").path
        let base64Result = Data(resultText.utf8).base64EncodedString()
        let script = """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> "\(argvLog)"; done
            cat > "\(stdinLog)"
            RESULT=$(echo "\(base64Result)" | base64 -D)
            python3 -c 'import json,sys; print(json.dumps({"result": sys.argv[1]}))' "$RESULT"
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }

    /// A fake `claude` that, on its Nth invocation (1-indexed, tracked via a counter file),
    /// returns `badText` and on every later invocation returns a `{"result": "<goodText>"}`
    /// envelope — used to test the "one retry after bad JSON" behavior.
    static func makeFakeClaudeBadThenGood(in dir: URL, badText: String, goodText: String) throws -> URL {
        let scriptPath = dir.appendingPathComponent("fake-claude-retry")
        let argvLog = dir.appendingPathComponent("argv.log").path
        let counterFile = dir.appendingPathComponent("counter").path
        let base64Bad = Data(badText.utf8).base64EncodedString()
        let base64Good = Data(goodText.utf8).base64EncodedString()
        let script = """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> "\(argvLog)"; done
            cat > /dev/null
            COUNT=0
            if [ -f "\(counterFile)" ]; then COUNT=$(cat "\(counterFile)"); fi
            COUNT=$((COUNT + 1))
            echo "$COUNT" > "\(counterFile)"
            if [ "$COUNT" -eq 1 ]; then
              RESULT=$(echo "\(base64Bad)" | base64 -D)
            else
              RESULT=$(echo "\(base64Good)" | base64 -D)
            fi
            python3 -c 'import json,sys; print(json.dumps({"result": sys.argv[1]}))' "$RESULT"
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }

    /// A fake CLI that ignores its input and sleeps far longer than any test timeout, to exercise
    /// the timeout-and-kill path. Traps SIGTERM so it only dies to SIGKILL, matching what a
    /// real, possibly-misbehaving CLI subprocess might do.
    static func makeFakeHangingProcess(in dir: URL) throws -> URL {
        let scriptPath = dir.appendingPathComponent("fake-hang")
        let script = """
            #!/bin/sh
            echo $$ > "\(hangPidFile(in: dir).path)"
            trap '' TERM
            cat > /dev/null &
            sleep \(hangSeconds)
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }

    /// Where the hanging fake records its own process id (before it starts sleeping).
    static func hangPidFile(in dir: URL) -> URL { dir.appendingPathComponent("hang.pid") }

    /// How long the hanging fake sleeps. A test can only run this long if the process was never killed.
    static let hangSeconds = 300

    /// Waits until the hanging fake's process is gone. Returns true when it is gone (or never got far
    /// enough to record its id, in which case it was killed before it started), false if it is still
    /// alive after `limit` seconds. Polls a real process table, so it does not depend on how fast the
    /// machine is, only on `limit` being generous.
    static func hangingProcessIsGone(in dir: URL, limit: Int = 60) async -> Bool {
        guard let text = try? String(contentsOf: hangPidFile(in: dir), encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        for _ in 0..<(limit * 20) {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// A fake `codex exec --json -` that logs argv/stdin and prints the `--json` event stream
    /// shape: a `thread.started` line, an `item.completed`/`agent_message` line carrying
    /// `messageText`, and a `turn.completed` line.
    static func makeFakeCodex(in dir: URL, messageText: String) throws -> URL {
        let scriptPath = dir.appendingPathComponent("fake-codex")
        let argvLog = dir.appendingPathComponent("argv.log").path
        let stdinLog = dir.appendingPathComponent("stdin.log").path
        let base64Message = Data(messageText.utf8).base64EncodedString()
        let script = """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> "\(argvLog)"; done
            cat > "\(stdinLog)"
            echo '{"type":"thread.started","thread_id":"fake"}'
            MESSAGE=$(echo "\(base64Message)" | base64 -D)
            python3 -c 'import json,sys; print(json.dumps({"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": sys.argv[1]}}))' "$MESSAGE"
            echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
            """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }

    /// Splits the recorded argv log on newlines, preserving an empty argument (e.g. `--tools`
    /// followed by `""`) as an empty string element rather than collapsing it away — an empty
    /// arg is meaningfully different from a missing one for a flag like `--tools ""`.
    static func readLines(_ path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func readFile(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
